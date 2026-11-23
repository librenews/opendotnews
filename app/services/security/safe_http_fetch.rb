require "net/http"
require "ipaddr"
require "resolv"
require "socket"
require "stringio"
require "zlib"
require "uri"

module Security
  class SafeHttpFetch
    class Error < StandardError; end
    class InvalidUrlError < Error; end
    class SsrfBlockedError < Error; end
    class TooManyRedirectsError < Error; end
    class ResponseTooLargeError < Error; end
    class NetworkError < Error; end

    Response = Data.define(
      :status,
      :body,
      :headers,
      :content_type,
      :final_url,
      :redirect_chain,
      :etag,
      :last_modified,
      :retry_after,
      :cache_control
    ) do
      def not_modified?
        status == 304
      end

      def success?
        status >= 200 && status < 300
      end
    end

    BLOCKED_CIDRS = [
      "0.0.0.0/8",          # "This" network
      "10.0.0.0/8",         # RFC1918
      "100.64.0.0/10",      # CGNAT / RFC6598
      "127.0.0.0/8",        # IPv4 loopback
      "169.254.0.0/16",     # Link-local / cloud metadata (IMDS)
      "172.16.0.0/12",      # RFC1918
      "192.0.0.0/24",       # IETF protocol assignments
      "192.0.2.0/24",       # TEST-NET-1
      "192.168.0.0/16",     # RFC1918
      "198.18.0.0/15",      # Benchmarking
      "198.51.100.0/24",    # TEST-NET-2
      "203.0.113.0/24",     # TEST-NET-3
      "224.0.0.0/4",        # Multicast
      "240.0.0.0/4",        # Reserved
      "255.255.255.255/32", # Broadcast
      "::/128",             # Unspecified
      "::1/128",            # IPv6 loopback
      "fc00::/7",           # IPv6 ULA
      "fe80::/10",          # IPv6 link-local
      "ff00::/8",           # IPv6 multicast
      "2001:db8::/32",      # Documentation
      "fd00:ec2::254/128"   # AWS IPv6 IMDS
    ].map { |cidr| IPAddr.new(cidr) }.freeze

    DEFAULT_RESOLVER = ->(host) {
      Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address).uniq
    }

    def self.get(url, **opts)
      new(**opts).get(url)
    end

    def self.blocked_ip?(raw_ip)
      ip = IPAddr.new(raw_ip.to_s)
      ip = ip.native if ip.ipv4_mapped?
      BLOCKED_CIDRS.any? { |cidr| cidr.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
    end

    def initialize(
      max_bytes: OpenNews.config.feed_max_bytes,
      max_decompressed_bytes: OpenNews.config.feed_max_decompressed_bytes,
      timeout: OpenNews.config.feed_http_timeout,
      max_redirects: OpenNews.config.feed_max_redirects,
      allow_private: OpenNews.config.allow_private_http_fetch,
      user_agent: OpenNews.config.user_agent,
      resolver: DEFAULT_RESOLVER,
      headers: {}
    )
      @max_bytes = max_bytes
      @max_decompressed_bytes = max_decompressed_bytes
      @timeout = timeout
      @max_redirects = max_redirects
      @allow_private = allow_private
      @user_agent = user_agent
      @resolver = resolver
      @extra_headers = headers || {}
    end

    def get(url, etag: nil, last_modified: nil)
      current_url = url.to_s.strip
      redirect_chain = []

      (@max_redirects + 1).times do |hop|
        uri = validate_uri!(current_url)
        pinned_ip = resolve_and_validate_ip!(uri.host)

        raw_response, raw_body = perform_request(uri, pinned_ip, etag: (hop == 0 ? etag : nil), last_modified: (hop == 0 ? last_modified : nil))
        code = raw_response.code.to_i

        if redirect_status?(code) && raw_response["location"].present?
          raise TooManyRedirectsError, "exceeded max redirects (#{@max_redirects})" if hop >= @max_redirects

          next_url = URI.join(uri.to_s, raw_response["location"].strip).to_s
          redirect_chain << current_url
          current_url = next_url
          next
        end

        body = code == 304 ? "" : decode_body(raw_body, raw_response["content-encoding"])
        headers_hash = normalize_headers(raw_response)

        return Response.new(
          status: code,
          body: body,
          headers: headers_hash,
          content_type: raw_response["content-type"].to_s,
          final_url: uri.to_s,
          redirect_chain: redirect_chain,
          etag: raw_response["etag"],
          last_modified: raw_response["last-modified"],
          retry_after: raw_response["retry-after"],
          cache_control: raw_response["cache-control"]
        )
      end

      raise TooManyRedirectsError, "exceeded max redirects (#{@max_redirects})"
    end

    private

    def validate_uri!(raw_url)
      raise InvalidUrlError, "URL cannot be blank" if raw_url.blank?
      raise InvalidUrlError, "URL contains control characters" if raw_url.match?(/[\x00-\x1f\x7f]/)

      uri = URI.parse(raw_url)
      unless %w[http https].include?(uri.scheme&.downcase)
        raise InvalidUrlError, "unsupported URL scheme #{uri.scheme.inspect}"
      end
      raise InvalidUrlError, "URL missing host" if uri.host.blank?
      raise InvalidUrlError, "URL userinfo not permitted" if uri.userinfo.present?

      uri
    rescue URI::InvalidURIError => e
      raise InvalidUrlError, "malformed URL: #{e.message}"
    end

    def resolve_and_validate_ip!(host)
      clean_host = host.delete_prefix("[").delete_suffix("]")

      # Literal IP address check
      begin
        IPAddr.new(clean_host)
        if !@allow_private && self.class.blocked_ip?(clean_host)
          raise SsrfBlockedError, "destination IP #{clean_host} is blocked"
        end
        return clean_host
      rescue IPAddr::InvalidAddressError
        # Hostname, proceed to DNS resolution
      end

      if !@allow_private && clean_host.downcase == "localhost"
        raise SsrfBlockedError, "destination localhost is blocked"
      end

      ips = Array(@resolver.call(clean_host))
      raise NetworkError, "DNS resolution returned no addresses for #{clean_host}" if ips.empty?

      unless @allow_private
        ips.each do |ip|
          if self.class.blocked_ip?(ip)
            raise SsrfBlockedError, "resolved IP #{ip} for #{clean_host} is blocked"
          end
        end
      end

      ips.first
    rescue SocketError, Resolv::ResolvError => e
      raise NetworkError, "DNS resolution failed for #{host}: #{e.message}"
    end

    def perform_request(uri, pinned_ip, etag:, last_modified:)
      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = pinned_ip if http.respond_to?(:ipaddr=) && !webmock_active?
      http.use_ssl = (uri.scheme.downcase == "https")
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = [ @timeout, 10 ].min
      http.read_timeout = @timeout
      http.write_timeout = [ @timeout, 10 ].min

      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"] = @user_agent
      req["Accept"] = "application/atom+xml, application/rss+xml, application/xml, text/xml;q=0.9, text/html;q=0.8, */*;q=0.5"
      req["Accept-Encoding"] = "gzip, deflate, identity"
      req["If-None-Match"] = etag if etag.present?
      req["If-Modified-Since"] = last_modified if last_modified.present?
      @extra_headers.each { |k, v| req[k] = v }

      raw_response = nil
      buffer = +"".b

      http.start do |conn|
        conn.request(req) do |resp|
          raw_response = resp
          content_length = resp["content-length"]&.to_i
          if content_length && content_length > @max_bytes
            raise ResponseTooLargeError, "response Content-Length #{content_length} exceeds limit #{@max_bytes}"
          end

          resp.read_body do |chunk|
            if buffer.bytesize + chunk.bytesize > @max_bytes
              raise ResponseTooLargeError, "response body exceeded limit #{@max_bytes} bytes"
            end
            buffer << chunk
          end
        end
      end

      [ raw_response, buffer ]
    rescue SsrfBlockedError, ResponseTooLargeError, InvalidUrlError
      raise
    rescue Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ETIMEDOUT,
           Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError, EOFError, IOError, SocketError => e
      raise NetworkError, "HTTP fetch failed: #{e.class}: #{e.message}"
    end

    def decode_body(raw_body, encoding)
      return raw_body if raw_body.empty?

      enc = encoding.to_s.downcase.strip
      case enc
      when "", "identity"
        raw_body
      when "gzip", "x-gzip"
        inflate_gzip_bounded(raw_body)
      when "deflate"
        inflate_deflate_bounded(raw_body)
      else
        raw_body
      end
    end

    def inflate_gzip_bounded(raw_body)
      gz = Zlib::GzipReader.new(StringIO.new(raw_body))
      out = +"".b
      while (chunk = gz.read(16_384))
        if out.bytesize + chunk.bytesize > @max_decompressed_bytes
          raise ResponseTooLargeError, "decompressed gzip body exceeded limit #{@max_decompressed_bytes} bytes"
        end
        out << chunk
      end
      out
    rescue Zlib::Error => e
      raise NetworkError, "invalid gzip stream: #{e.message}"
    ensure
      gz&.close
    end

    def inflate_deflate_bounded(raw_body)
      z = Zlib::Inflate.new
      out = +"".b
      offset = 0
      while offset < raw_body.bytesize
        piece = z.inflate(raw_body.byteslice(offset, 16_384))
        if out.bytesize + piece.bytesize > @max_decompressed_bytes
          raise ResponseTooLargeError, "decompressed deflate body exceeded limit #{@max_decompressed_bytes} bytes"
        end
        out << piece
        offset += 16_384
      end
      tail = z.finish
      if out.bytesize + tail.bytesize > @max_decompressed_bytes
        raise ResponseTooLargeError, "decompressed deflate body exceeded limit #{@max_decompressed_bytes} bytes"
      end
      out << tail
    rescue Zlib::Error => e
      raise NetworkError, "invalid deflate stream: #{e.message}"
    ensure
      z&.close
    end

    def redirect_status?(code)
      [ 301, 302, 303, 307, 308 ].include?(code)
    end

    def normalize_headers(resp)
      out = {}
      resp.each_header { |k, v| out[k.downcase] = v }
      out
    end

    def webmock_active?
      defined?(WebMock) && Rails.env.test?
    end
  end
end
