require "nokogiri"
require "uri"

module RssCloud
  # Outbound rssCloud cloud server serving public hosted RSS 2.0 feeds on this Open.News instance.
  # Supports REST (http-post) and XML-RPC (pleaseNotify / RPC2) registrations, challenge verification,
  # 25-hour finite leases, and lightweight feed-URL ping fanout.
  class Cloud
    LEASE_SECONDS = 25.hours.to_i
    STRICT_XML_OPTIONS = Nokogiri::XML::ParseOptions::NONET | Nokogiri::XML::ParseOptions::NOBLANKS

    Result = Data.define(:status, :subscriptions, :body, :content_type, :http_status, :error) do
      def ok?
        status == :ok
      end
    end

    def self.register_rest(params:, remote_ip:, fetcher: nil)
      new(fetcher: fetcher).register_rest(params: params, remote_ip: remote_ip)
    end

    def self.register_xmlrpc(raw_xml:, remote_ip:, fetcher: nil)
      new(fetcher: fetcher).register_xmlrpc(raw_xml: raw_xml, remote_ip: remote_ip)
    end

    def self.ping(raw_topic_url:)
      new.ping(raw_topic_url: raw_topic_url)
    end

    def self.deliver!(subscription:, outbox_event:, attempt_number: 1, fetcher: nil)
      new(fetcher: fetcher).deliver!(subscription: subscription, outbox_event: outbox_event, attempt_number: attempt_number)
    end

    def initialize(fetcher: nil)
      @fetcher = fetcher || Security::SafeHttpFetch.new
    end

    # POST /rsscloud/pleaseNotify (REST http-post registration)
    def register_rest(params:, remote_ip:)
      domain = params["domain"].to_s.strip.presence || remote_ip.to_s.strip
      port = params["port"].to_i
      port = 80 if port <= 0
      path = params["path"].to_s.strip
      protocol_variant = params["protocol"].to_s.strip.downcase.presence || "http-post"
      notify_proc = params["notifyProcedure"].to_s.strip

      urls = extract_rest_urls(params)
      if domain.blank? || path.blank? || urls.empty?
        return rest_error("Missing required registration parameters (domain, path, url1)")
      end
      unless %w[http-post xml-rpc].include?(protocol_variant)
        return rest_error("Unsupported protocol #{protocol_variant.inspect} (http-post or xml-rpc required)")
      end

      callback_url = build_callback_url(domain: domain, port: port, path: path)
      return rest_error("Invalid callback URL") unless callback_url

      subs = []
      urls.first(25).each do |raw_url|
        resolved = Publishing::HostedTopicResolver.resolve(raw_url, allowed_formats: %w[rss])
        return rest_error("Topic #{raw_url} is not a hosted RSS feed on this instance") unless resolved

        ok, err = verify_and_activate_rest!(resolved, callback_url: callback_url, protocol_variant: protocol_variant, notify_proc: notify_proc)
        return rest_error(err) unless ok

        subs << ok
      end

      xml = %(<?xml version="1.0" encoding="UTF-8"?>\n<notifyResult success="true" msg="Thanks for the registration."/>\n)
      Result.new(status: :ok, subscriptions: subs, body: xml, content_type: "text/xml; charset=utf-8", http_status: 200, error: nil)
    end

    # POST /rsscloud/RPC2 (XML-RPC pleaseNotify registration)
    def register_xmlrpc(raw_xml:, remote_ip:)
      if raw_xml.to_s.bytesize > 64 * 1024
        return xmlrpc_fault("XML-RPC payload too large", http_status: 413)
      end
      if raw_xml.to_s.match?(/<!ENTITY\b/i) || raw_xml.to_s.match?(/<!DOCTYPE[^>]*(SYSTEM|PUBLIC|\[)/im)
        return xmlrpc_fault("XML DOCTYPE/ENTITY declarations are forbidden")
      end

      doc = Nokogiri::XML(raw_xml.to_s, nil, nil, STRICT_XML_OPTIONS)
      method_name = doc.at_xpath("//methodCall/methodName")&.text&.strip
      unless %w[rssCloud.pleaseNotify pleaseNotify].include?(method_name)
        return xmlrpc_fault("Unsupported XML-RPC method #{method_name.inspect}")
      end

      param_nodes = doc.xpath("//methodCall/params/param")
      if param_nodes.size < 5
        return xmlrpc_fault("pleaseNotify requires 5 parameters")
      end

      notify_proc = param_nodes[0].text.strip
      port = param_nodes[1].text.strip.to_i
      port = 80 if port <= 0
      path = param_nodes[2].text.strip
      protocol_variant = param_nodes[3].text.strip.downcase
      urls = param_nodes[4].xpath(".//data/value").map { |v| v.text.strip }.reject(&:blank?)
      domain = (param_nodes[5]&.text&.strip).presence || remote_ip.to_s.strip

      unless %w[http-post xml-rpc].include?(protocol_variant) && domain.present? && path.present? && urls.any?
        return xmlrpc_fault("Invalid pleaseNotify parameters")
      end

      callback_url = build_callback_url(domain: domain, port: port, path: path)
      return xmlrpc_fault("Invalid callback URL") unless callback_url

      subs = []
      urls.first(25).each do |raw_url|
        resolved = Publishing::HostedTopicResolver.resolve(raw_url, allowed_formats: %w[rss])
        return xmlrpc_fault("Topic #{raw_url} is not a hosted RSS feed on this instance") unless resolved

        ok, err = verify_and_activate_rest!(resolved, callback_url: callback_url, protocol_variant: protocol_variant, notify_proc: notify_proc)
        return xmlrpc_fault(err) unless ok

        subs << ok
      end

      xml = %(<?xml version="1.0" encoding="UTF-8"?>\n<methodResponse><params><param><value><boolean>1</boolean></value></param></params></methodResponse>\n)
      Result.new(status: :ok, subscriptions: subs, body: xml, content_type: "text/xml; charset=utf-8", http_status: 200, error: nil)
    rescue Nokogiri::XML::SyntaxError => e
      xmlrpc_fault("Malformed XML-RPC: #{e.message}")
    end

    # POST /rsscloud/ping — guarded ping for hosted RSS feeds only (rejects arbitrary remote URLs).
    def ping(raw_topic_url:)
      resolved = Publishing::HostedTopicResolver.resolve(raw_topic_url, allowed_formats: %w[rss])
      unless resolved
        xml = %(<?xml version="1.0" encoding="UTF-8"?>\n<pingResult success="false" msg="Only public hosted RSS feeds on this instance may be pinged."/>\n)
        return Result.new(status: :forbidden, subscriptions: [], body: xml, content_type: "text/xml; charset=utf-8", http_status: 403, error: "Unowned topic")
      end

      # Only trigger fanout if the publication actually has a recent committed change.
      latest_change = OutboxEvent.where(event_type: "publication.feed_changed")
        .where("payload ->> 'publication_id' = ?", resolved.publication.id)
        .order(created_at: :desc)
        .first

      if latest_change
        Publishing::FanoutFeedChangeJob.perform_async(latest_change.id)
      end

      xml = %(<?xml version="1.0" encoding="UTF-8"?>\n<pingResult success="true" msg="Ping accepted for hosted feed."/>\n)
      Result.new(status: :ok, subscriptions: [], body: xml, content_type: "text/xml; charset=utf-8", http_status: 200, error: nil)
    end

    # Lightweight rssCloud notification carrying ONLY the changed feed URL (never Markdown or JSON).
    def deliver!(subscription:, outbox_event:, attempt_number: 1)
      return :inactive unless subscription.active?

      attempt = find_or_create_attempt!(subscription, outbox_event, attempt_number)
      return :already_delivered if attempt.status == "delivered"

      variant = subscription.metadata&.dig("protocol_variant").presence || "http-post"
      resp = if variant == "xml-rpc"
        notify_proc = subscription.metadata&.dig("notify_procedure").presence || "rssPleaseNotify"
        xml_body = build_xmlrpc_ping(notify_proc, subscription.topic_url)
        @fetcher.post(subscription.callback_url, body: xml_body, content_type: "text/xml; charset=utf-8")
      else
        form_body = URI.encode_www_form("url" => subscription.topic_url)
        @fetcher.post(subscription.callback_url, body: form_body, content_type: "application/x-www-form-urlencoded")
      end

      Delivery::OutcomeHandler.record_response!(subscription: subscription, attempt: attempt, response: resp)
    rescue Security::SafeHttpFetch::SsrfBlockedError => e
      Delivery::OutcomeHandler.record_error!(subscription: subscription, attempt: attempt, error: e, ssrf_blocked: true)
    rescue Security::SafeHttpFetch::Error => e
      Delivery::OutcomeHandler.record_error!(subscription: subscription, attempt: attempt, error: e)
    end

    private

    def verify_and_activate_rest!(resolved, callback_url:, protocol_variant:, notify_proc:)
      # Always verify callback reachability & challenge (via SSRF-safe HTTP fetch) BEFORE activating!
      challenge = SecureRandom.urlsafe_base64(24)
      verify_uri = URI.parse(callback_url)
      existing_q = URI.decode_www_form(verify_uri.query.to_s)
      verify_uri.query = URI.encode_www_form(existing_q + [ [ "url", resolved.canonical_topic_url ], [ "challenge", challenge ] ])

      resp = @fetcher.get(verify_uri.to_s)
      unless resp.success? && resp.body.to_s.strip == challenge
        return [ nil, "Callback verification failed (HTTP #{resp.status})" ]
      end

      now = Time.current
      cb_host = URI.parse(callback_url).host.downcase
      sub = DownstreamSubscription.find_or_initialize_by(
        protocol: "rsscloud",
        topic_url: resolved.canonical_topic_url,
        callback_url: callback_url
      )
      sub.assign_attributes(
        publication: resolved.publication,
        topic_format: "rss",
        callback_host: cb_host,
        status: "active",
        lease_seconds: LEASE_SECONDS,
        lease_expires_at: now + LEASE_SECONDS.seconds,
        failure_count: 0,
        last_error: nil,
        metadata: {
          "protocol_variant" => protocol_variant,
          "notify_procedure" => notify_proc.presence
        }.compact
      )
      sub.save!
      [ sub, nil ]
    rescue Security::SafeHttpFetch::Error => e
      [ nil, "Callback blocked or unreachable: #{e.message}" ]
    end

    def extract_rest_urls(params)
      urls = []
      params.each do |k, v|
        urls << v.to_s.strip if k.to_s.match?(/\Aurl\d*\z/i) && v.present?
      end
      urls.uniq
    end

    def build_callback_url(domain:, port:, path:)
      clean_path = path.start_with?("/") ? path : "/#{path}"
      scheme = (port == 443) ? "https" : "http"
      port_part = %w[80 443].include?(port.to_s) ? "" : ":#{port}"
      Feeds::UrlNormalizer.normalize("#{scheme}://#{domain}#{port_part}#{clean_path}")
    end

    def build_xmlrpc_ping(notify_proc, topic_url)
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.methodCall do
          xml.methodName notify_proc
          xml.params do
            xml.param { xml.value { xml.string topic_url } }
          end
        end
      end.to_xml
    end

    def find_or_create_attempt!(subscription, outbox_event, attempt_number)
      DeliveryAttempt.find_or_create_by!(
        downstream_subscription: subscription,
        outbox_event: outbox_event,
        attempt_number: attempt_number
      ) { |a| a.status = "pending" }
    rescue ActiveRecord::RecordNotUnique
      DeliveryAttempt.find_by!(
        downstream_subscription: subscription,
        outbox_event: outbox_event,
        attempt_number: attempt_number
      )
    end

    def rest_error(msg, http_status: 400)
      escaped = CGI.escapeHTML(msg.to_s.truncate(250))
      xml = %(<?xml version="1.0" encoding="UTF-8"?>\n<notifyResult success="false" msg="#{escaped}"/>\n)
      Result.new(status: :error, subscriptions: [], body: xml, content_type: "text/xml; charset=utf-8", http_status: http_status, error: msg)
    end

    def xmlrpc_fault(msg, http_status: 400)
      escaped = CGI.escapeHTML(msg.to_s.truncate(250))
      xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <methodResponse><fault><value><struct>
          <member><name>faultCode</name><value><int>400</int></value></member>
          <member><name>faultString</name><value><string>#{escaped}</string></value></member>
        </struct></value></fault></methodResponse>
      XML
      Result.new(status: :error, subscriptions: [], body: xml, content_type: "text/xml; charset=utf-8", http_status: http_status, error: msg)
    end
  end
end
