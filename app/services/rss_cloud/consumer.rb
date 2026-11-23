require "nokogiri"
require "uri"

module RssCloud
  class Consumer
    LEASE_SECONDS = 25.hours.to_i
    RENEW_BEFORE_EXPIRY = 2.hours
    PING_COOLDOWN_SECONDS = 30
    STRICT_XML_OPTIONS = Nokogiri::XML::ParseOptions::NONET | Nokogiri::XML::ParseOptions::NOBLANKS

    Result = Data.define(:status, :subscription, :body, :content_type, :http_status, :enqueued_fetch, :error) do
      def ok?
        status == :ok
      end
    end

    def self.register(feed, fetcher: nil)
      new(fetcher: fetcher).register(feed)
    end

    def self.renew(subscription, fetcher: nil)
      new(fetcher: fetcher).renew(subscription)
    end

    def self.verify_challenge(raw_token:, params:)
      new.verify_challenge(raw_token: raw_token, params: params)
    end

    def self.receive_ping(raw_token:, raw_body:, params:, content_type:)
      new.receive_ping(raw_token: raw_token, raw_body: raw_body, params: params, content_type: content_type)
    end

    def initialize(fetcher: nil)
      @fetcher = fetcher || Security::SafeHttpFetch.new
    end

    def register(feed)
      endpoint = Feeds::UrlNormalizer.normalize(feed.discovered_rsscloud_endpoint)
      topic_url = Feeds::UrlNormalizer.normalize(feed.canonical_url)
      protocol_variant = feed.discovered_rsscloud_protocol.to_s.downcase.presence || "http-post"

      if endpoint.blank? || topic_url.blank?
        return error_result(nil, "Feed does not advertise a valid rssCloud endpoint")
      end

      unless %w[http-post xml-rpc].include?(protocol_variant)
        return error_result(nil, "Unsupported rssCloud protocol #{protocol_variant.inspect} (http-post and xml-rpc supported)")
      end

      sub = find_or_initialize_live_subscription(feed, endpoint, topic_url, protocol_variant)
      send_registration(sub)
    end

    def renew(subscription)
      return error_result(subscription, "Not an rssCloud subscription") unless subscription.protocol == "rsscloud"

      send_registration(subscription)
    end

    # GET /callbacks/rsscloud/:token?url=...&challenge=...
    def verify_challenge(raw_token:, params:)
      sub = UpstreamPushSubscription.find_by_raw_token(raw_token)
      unless sub && sub.protocol == "rsscloud"
        return Result.new(status: :not_found, subscription: nil, body: "Not found", content_type: "text/plain", http_status: 404, enqueued_fetch: false, error: "Unknown callback token")
      end

      challenge = params["challenge"].to_s
      url_param = Feeds::UrlNormalizer.normalize(params["url"].to_s)

      if challenge.blank? || (url_param.present? && url_param != Feeds::UrlNormalizer.normalize(sub.topic_url))
        return Result.new(status: :forbidden, subscription: sub, body: "Invalid challenge or topic URL", content_type: "text/plain", http_status: 403, enqueued_fetch: false, error: "Invalid challenge")
      end

      now = Time.current
      sub.update!(
        status: "active",
        lease_seconds: LEASE_SECONDS,
        lease_expires_at: now + LEASE_SECONDS.seconds,
        last_confirmed_at: now,
        next_renew_at: now + LEASE_SECONDS.seconds - RENEW_BEFORE_EXPIRY,
        failure_count: 0,
        last_error: nil
      )

      Result.new(status: :ok, subscription: sub, body: challenge, content_type: "text/plain; charset=utf-8", http_status: 200, enqueued_fetch: false, error: nil)
    end

    # POST /callbacks/rsscloud/:token — accepts REST form POST or XML-RPC rssPleaseNotify ping.
    # Treats ping strictly as an untrusted trigger to enqueue a coalesced Feeds::FetchJob.
    def receive_ping(raw_token:, raw_body:, params:, content_type:)
      if raw_body.to_s.bytesize > 64 * 1024
        return Result.new(status: :too_large, subscription: nil, body: "Payload too large", content_type: "text/plain", http_status: 413, enqueued_fetch: false, error: "Ping payload too large")
      end

      sub = UpstreamPushSubscription.find_by_raw_token(raw_token)
      unless sub && sub.protocol == "rsscloud" && %w[active pending].include?(sub.status)
        return Result.new(status: :not_found, subscription: nil, body: "Not found", content_type: "text/plain", http_status: 404, enqueued_fetch: false, error: "Unknown or inactive subscription")
      end

      is_xmlrpc = content_type.to_s.downcase.include?("xml") || raw_body.to_s.lstrip.start_with?("<")
      pinged_url = if is_xmlrpc
        extract_xmlrpc_ping_url(raw_body)
      else
        params["url"].to_s.presence || URI.decode_www_form(raw_body.to_s).to_h["url"]
      end

      norm_ping = Feeds::UrlNormalizer.normalize(pinged_url)
      if norm_ping.blank? || norm_ping != Feeds::UrlNormalizer.normalize(sub.topic_url)
        return Result.new(status: :forbidden, subscription: sub, body: "Unknown or mismatched topic URL", content_type: "text/plain", http_status: 403, enqueued_fetch: false, error: "Topic mismatch")
      end

      now = Time.current
      enqueued = enqueue_coalesced_fetch!(sub, now)

      if is_xmlrpc
        xml_ok = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <methodResponse><params><param><value><boolean>1</boolean></value></param></params></methodResponse>
        XML
        Result.new(status: :ok, subscription: sub, body: xml_ok, content_type: "text/xml; charset=utf-8", http_status: 200, enqueued_fetch: enqueued, error: nil)
      else
        Result.new(status: :ok, subscription: sub, body: "Thanks for the update", content_type: "text/plain; charset=utf-8", http_status: 200, enqueued_fetch: enqueued, error: nil)
      end
    rescue Nokogiri::XML::SyntaxError, ArgumentError => e
      Result.new(status: :bad_request, subscription: sub, body: "Malformed ping payload", content_type: "text/plain", http_status: 400, enqueued_fetch: false, error: e.message)
    end

    private

    def enqueue_coalesced_fetch!(sub, now)
      enqueued = false
      sub.with_lock do
        meta = sub.metadata || {}
        last_enqueued = meta["last_ping_enqueued_at"] ? Time.parse(meta["last_ping_enqueued_at"]) : nil
        ping_count = meta["ping_count"].to_i + 1

        cooldown_active = last_enqueued && (now - last_enqueued) < PING_COOLDOWN_SECONDS
        if !cooldown_active
          Feeds::FetchJob.perform_async(sub.feed_id)
          enqueued = true
          meta = meta.merge("last_ping_enqueued_at" => now.iso8601)
        end

        sub.update!(
          last_delivery_at: now,
          metadata: meta.merge("ping_count" => ping_count)
        )
      end
      enqueued
    end

    def extract_xmlrpc_ping_url(raw_xml)
      xml = raw_xml.to_s
      if xml.match?(/<!ENTITY\b/i) || xml.match?(/<!DOCTYPE[^>]*(SYSTEM|PUBLIC|\[)/im)
        raise ArgumentError, "XXE declarations forbidden"
      end

      doc = Nokogiri::XML(xml, nil, nil, STRICT_XML_OPTIONS)
      doc.at_xpath("//methodCall/params/param[1]/value/string")&.text&.strip ||
        doc.at_xpath("//methodCall/params/param[1]/value")&.text&.strip
    end

    def find_or_initialize_live_subscription(feed, endpoint, topic_url, protocol_variant)
      existing = UpstreamPushSubscription.live.find_by(
        feed_id: feed.id,
        protocol: "rsscloud",
        hub_url: endpoint,
        topic_url: topic_url
      )
      return existing if existing

      raw_token = SecureRandom.urlsafe_base64(32)
      register_proc = feed.source_metadata&.dig("rsscloud_register_procedure")
      UpstreamPushSubscription.create!(
        feed: feed,
        protocol: "rsscloud",
        hub_url: endpoint,
        topic_url: topic_url,
        callback_token: raw_token,
        callback_token_digest: UpstreamPushSubscription.digest_token(raw_token),
        status: "pending",
        requested_mode: "subscribe",
        metadata: {
          "protocol_variant" => protocol_variant,
          "register_procedure" => register_proc
        }.compact
      )
    rescue ActiveRecord::RecordNotUnique
      UpstreamPushSubscription.live.find_by!(feed_id: feed.id, protocol: "rsscloud", hub_url: endpoint, topic_url: topic_url)
    end

    def send_registration(sub)
      now = Time.current
      cb_uri = URI.parse(sub.callback_url)
      port = cb_uri.port || (cb_uri.scheme == "https" ? 443 : 80)
      variant = sub.metadata&.dig("protocol_variant") || "http-post"

      sub.update!(last_requested_at: now)

      resp = if variant == "xml-rpc"
        send_xmlrpc_registration(sub, cb_uri, port)
      else
        send_rest_registration(sub, cb_uri, port)
      end

      unless resp.success?
        return record_failure!(sub, "rssCloud server returned HTTP #{resp.status}", now: now)
      end

      if registration_accepted?(resp.body, variant)
        expires_at = now + LEASE_SECONDS.seconds
        sub.update!(
          status: "active",
          lease_seconds: LEASE_SECONDS,
          lease_expires_at: expires_at,
          last_confirmed_at: sub.last_confirmed_at || now,
          next_renew_at: expires_at - RENEW_BEFORE_EXPIRY,
          failure_count: 0,
          last_error: nil
        )
        Result.new(status: :ok, subscription: sub, body: resp.body, content_type: resp.content_type, http_status: resp.status, enqueued_fetch: false, error: nil)
      else
        record_failure!(sub, "rssCloud registration rejected: #{resp.body.to_s.truncate(200)}", now: now)
      end
    rescue Security::SafeHttpFetch::Error => e
      record_failure!(sub, e.message, now: Time.current)
    end

    def send_rest_registration(sub, cb_uri, port)
      form = {
        "notifyProcedure" => "",
        "domain" => cb_uri.host,
        "port" => port.to_s,
        "path" => cb_uri.path,
        "protocol" => "http-post",
        "url1" => sub.topic_url
      }
      @fetcher.post(sub.hub_url, body: URI.encode_www_form(form), content_type: "application/x-www-form-urlencoded")
    end

    def send_xmlrpc_registration(sub, cb_uri, port)
      reg_proc = sub.metadata&.dig("register_procedure").presence || "rssCloud.pleaseNotify"
      builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.methodCall do
          xml.methodName reg_proc
          xml.params do
            xml.param { xml.value { xml.string "rssPleaseNotify" } }
            xml.param { xml.value { xml.int port } }
            xml.param { xml.value { xml.string cb_uri.path } }
            xml.param { xml.value { xml.string "xml-rpc" } }
            xml.param do
              xml.value do
                xml.array do
                  xml.data do
                    xml.value { xml.string sub.topic_url }
                  end
                end
              end
            end
          end
        end
      end
      @fetcher.post(sub.hub_url, body: builder.to_xml, content_type: "text/xml; charset=utf-8")
    end

    def registration_accepted?(body, variant)
      raw = body.to_s
      return false if raw.match?(/<!ENTITY\b/i)

      doc = Nokogiri::XML(raw, nil, nil, STRICT_XML_OPTIONS)
      if variant == "xml-rpc"
        val = doc.at_xpath("//methodResponse/params/param/value/boolean")&.text&.strip
        val == "1" || val == "true"
      else
        node = doc.at_xpath("//notifyResult")
        node ? node["success"].to_s.downcase == "true" : true
      end
    rescue Nokogiri::XML::SyntaxError
      false
    end

    def record_failure!(sub, message, now:)
      failures = sub.failure_count + 1
      backoff = [ 15.minutes * (2**(failures - 1)), 24.hours ].min
      sub.update!(
        status: sub.active? ? "active" : "error",
        failure_count: failures,
        last_error: message.to_s.truncate(1000),
        next_renew_at: now + backoff
      )
      error_result(sub, message)
    end

    def error_result(sub, message)
      Result.new(status: :error, subscription: sub, body: nil, content_type: nil, http_status: nil, enqueued_fetch: false, error: message)
    end
  end
end
