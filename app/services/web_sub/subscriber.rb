require "openssl"
require "digest"
require "uri"

module WebSub
  class Subscriber
    DEFAULT_LEASE_SECONDS = 5.days.to_i # 432,000 seconds
    SUPPORTED_HMAC_ALGORITHMS = {
      "sha256" => "SHA256",
      "sha384" => "SHA384",
      "sha512" => "SHA512",
      "sha1"   => "SHA1" # Legacy hub compatibility; prefer sha256 when multiple signatures present
    }.freeze

    Result = Data.define(:status, :subscription, :body, :content_type, :http_status, :error) do
      def ok?
        status == :ok
      end
    end

    def self.subscribe(feed, fetcher: nil)
      new(fetcher: fetcher).subscribe(feed)
    end

    def self.renew(subscription, fetcher: nil)
      new(fetcher: fetcher).renew(subscription)
    end

    def self.unsubscribe(subscription, fetcher: nil)
      new(fetcher: fetcher).unsubscribe(subscription)
    end

    def self.verify_intent(raw_token:, params:)
      new.verify_intent(raw_token: raw_token, params: params)
    end

    def self.receive_distribution(raw_token:, raw_body:, headers:)
      new.receive_distribution(raw_token: raw_token, raw_body: raw_body, headers: headers)
    end

    def self.process_staged_payload(staged_payload_id)
      new.process_staged_payload(staged_payload_id)
    end

    def self.verify_signature(secret:, signature_header:, raw_body:)
      return false if secret.blank? || signature_header.blank?

      # Support comma-separated signature headers (e.g., "sha1=..., sha256=...")
      candidates = signature_header.to_s.split(",").map(&:strip).reject(&:blank?)
      return false if candidates.empty?

      parsed = candidates.filter_map do |entry|
        algo, hex_sig = entry.split("=", 2)
        next unless algo && hex_sig && SUPPORTED_HMAC_ALGORITHMS.key?(algo.downcase)

        [ algo.downcase, hex_sig.strip.downcase ]
      end
      return false if parsed.empty?

      # If any strong SHA-2 signature is present, require a strong one to match (never downgrade to sha1).
      strong = parsed.select { |algo, _| algo != "sha1" }
      to_check = strong.any? ? strong : parsed

      to_check.any? do |algo, provided_hex|
        digest_name = SUPPORTED_HMAC_ALGORITHMS[algo]
        expected_hex = OpenSSL::HMAC.hexdigest(digest_name, secret, raw_body.to_s)
        provided_hex.bytesize == expected_hex.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(provided_hex, expected_hex)
      end
    end

    def initialize(fetcher: nil)
      @fetcher = fetcher || Security::SafeHttpFetch.new
    end

    def subscribe(feed)
      hub_url = Feeds::UrlNormalizer.normalize(feed.discovered_websub_hub)
      topic_url = Feeds::UrlNormalizer.normalize(feed.discovered_websub_topic.presence || feed.canonical_url)
      if hub_url.blank? || topic_url.blank?
        return Result.new(status: :error, subscription: nil, body: nil, content_type: nil, http_status: nil, error: "Feed does not advertise a valid WebSub hub")
      end

      sub = find_or_initialize_live_subscription(feed, hub_url, topic_url)
      send_hub_request(sub, mode: "subscribe")
    end

    def renew(subscription)
      return Result.new(status: :error, subscription: subscription, body: nil, content_type: nil, http_status: nil, error: "Not a WebSub subscription") unless subscription.protocol == "websub"

      send_hub_request(subscription, mode: "subscribe")
    end

    def unsubscribe(subscription)
      return Result.new(status: :error, subscription: subscription, body: nil, content_type: nil, http_status: nil, error: "Not a WebSub subscription") unless subscription.protocol == "websub"

      subscription.update!(status: "unsubscribing", requested_mode: "unsubscribe")
      send_hub_request(subscription, mode: "unsubscribe")
    end

    # W3C WebSub Section 5.3 — Verification of Intent (GET /callbacks/websub/:token)
    def verify_intent(raw_token:, params:)
      sub = UpstreamPushSubscription.find_by_raw_token(raw_token)
      unless sub && sub.protocol == "websub"
        return Result.new(status: :not_found, subscription: nil, body: "Not found", content_type: "text/plain", http_status: 404, error: "Unknown callback token")
      end

      mode = params["hub.mode"].to_s.strip
      topic = Feeds::UrlNormalizer.normalize(params["hub.topic"].to_s)
      challenge = params["hub.challenge"].to_s

      if topic != Feeds::UrlNormalizer.normalize(sub.topic_url)
        return Result.new(status: :not_found, subscription: sub, body: "Topic mismatch", content_type: "text/plain", http_status: 404, error: "Topic mismatch")
      end

      if mode == "denied"
        reason = params["hub.reason"].to_s.truncate(500)
        sub.update!(
          status: "error",
          failure_count: sub.failure_count + 1,
          last_error: "Hub denied subscription#{reason.present? ? ": #{reason}" : ""}",
          next_renew_at: 6.hours.from_now
        )
        return Result.new(status: :ok, subscription: sub, body: "Acknowledged denial", content_type: "text/plain", http_status: 200, error: nil)
      end

      unless %w[subscribe unsubscribe].include?(mode) && mode == sub.requested_mode && challenge.present?
        return Result.new(status: :not_found, subscription: sub, body: "Unexpected verification", content_type: "text/plain", http_status: 404, error: "Unexpected verification mode or missing challenge")
      end

      now = Time.current
      if mode == "subscribe"
        lease = params["hub.lease_seconds"].to_i
        lease = DEFAULT_LEASE_SECONDS if lease <= 0
        lease = lease.clamp(60, 30.days.to_i)
        expires_at = now + lease.seconds
        margin = [ (lease * 0.2).to_i, 6.hours.to_i ].min
        jitter = (margin * (rand * 0.1)).to_i
        renew_at = expires_at - [ margin + jitter, lease - 30 ].min.seconds

        sub.update!(
          status: "active",
          lease_seconds: lease,
          lease_expires_at: expires_at,
          last_confirmed_at: now,
          next_renew_at: renew_at,
          failure_count: 0,
          last_error: nil
        )
      else
        sub.update!(
          status: "unsubscribed",
          last_confirmed_at: now,
          next_renew_at: nil,
          last_error: nil
        )
      end

      Result.new(status: :ok, subscription: sub, body: challenge, content_type: "text/plain; charset=utf-8", http_status: 200, error: nil)
    end

    # W3C WebSub Section 7 — Content Distribution (POST /callbacks/websub/:token)
    def receive_distribution(raw_token:, raw_body:, headers:)
      if raw_body.bytesize > OpenNews.config.feed_max_bytes
        return Result.new(status: :too_large, subscription: nil, body: "Payload too large", content_type: "text/plain", http_status: 413, error: "Payload exceeds limit")
      end

      sub = UpstreamPushSubscription.find_by_raw_token(raw_token)
      unless sub && sub.protocol == "websub" && sub.active?
        return Result.new(status: :not_found, subscription: nil, body: "Not found", content_type: "text/plain", http_status: 404, error: "Unknown or inactive subscription")
      end

      norm_headers = (headers || {}).transform_keys(&:downcase)

      # When a shared secret was negotiated, valid HMAC signature is strictly mandatory.
      if sub.secret.present?
        sig = norm_headers["x-hub-signature"]
        unless self.class.verify_signature(secret: sub.secret, signature_header: sig, raw_body: raw_body)
          Rails.logger.warn("WebSub rejected invalid/missing X-Hub-Signature for subscription=#{sub.id} feed=#{sub.feed_id}")
          return Result.new(status: :forbidden, subscription: sub, body: "Invalid signature", content_type: "text/plain", http_status: 403, error: "Invalid or missing X-Hub-Signature")
        end
      end

      now = Time.current
      staged = StagedPushPayload.create!(
        upstream_push_subscription: sub,
        feed: sub.feed,
        content_type: norm_headers["content-type"].to_s.truncate(255),
        headers: norm_headers.slice("content-type", "link", "etag", "last-modified"),
        body: raw_body.dup.force_encoding("UTF-8").scrub,
        body_sha256: Digest::SHA256.hexdigest(raw_body),
        status: "pending",
        received_at: now
      )

      sub.update_columns(last_delivery_at: now, updated_at: now)
      Push::AcceptWebSubPayloadJob.perform_async(staged.id)

      Result.new(status: :ok, subscription: sub, body: "Accepted", content_type: "text/plain", http_status: 202, error: nil)
    end

    # Async worker handler: ingests verified full RSS/Atom feed directly WITHOUT redundant HTTP fetch.
    # Falls back to a guarded Feeds::FetchJob if payload is malformed or unsupported content-type.
    def process_staged_payload(staged_payload_id)
      staged = StagedPushPayload.includes(:feed, :upstream_push_subscription).find_by(id: staged_payload_id)
      return :missing unless staged
      return :already_processed if staged.status == "processed"

      feed = staged.feed
      sub = staged.upstream_push_subscription
      ct = staged.content_type.to_s.downcase

      # Never interpret arbitrary JSON callbacks as authenticated feed content.
      if ct.include?("application/json")
        return fail_and_fallback!(staged, feed, "Unsupported WebSub JSON content-type; scheduling guarded fetch")
      end

      adapter = Sources::Adapters::FeedAdapter.new
      parsed = adapter.parse_payload(staged.body, headers: staged.headers || {}, base_url: sub.topic_url)

      Feeds::Ingest.call(
        feed: feed,
        normalized_items: parsed[:items],
        source_attributes: parsed[:source_attributes],
        source_metadata: parsed[:source_metadata],
        raw_body: staged.body,
        etag: staged.headers&.dig("etag"),
        last_modified: staged.headers&.dig("last-modified"),
        ingestion_method: "websub",
        http_status: 200,
        diagnostics: parsed[:diagnostics].merge("websub_subscription_id" => sub.id, "staged_payload_id" => staged.id)
      )

      staged.update!(status: "processed", processed_at: Time.current, error_message: nil)
      :ok
    rescue Feeds::Parse::ParseError => e
      fail_and_fallback!(staged, staged.feed, "WebSub payload parse failed (#{e.message}); scheduling guarded fetch")
    end

    private

    def fail_and_fallback!(staged, feed, message)
      staged.update!(status: "failed", error_message: message.truncate(1000), processed_at: Time.current)
      Feeds::FetchJob.perform_async(feed.id)
      :fallback_fetch
    end

    def find_or_initialize_live_subscription(feed, hub_url, topic_url)
      existing = UpstreamPushSubscription.live.find_by(
        feed_id: feed.id,
        protocol: "websub",
        hub_url: hub_url,
        topic_url: topic_url
      )
      return existing if existing

      raw_token = SecureRandom.urlsafe_base64(32)
      UpstreamPushSubscription.create!(
        feed: feed,
        protocol: "websub",
        hub_url: hub_url,
        topic_url: topic_url,
        callback_token: raw_token,
        callback_token_digest: UpstreamPushSubscription.digest_token(raw_token),
        secret: SecureRandom.hex(32), # 64 ASCII chars (< 200 byte W3C limit)
        status: "pending",
        requested_mode: "subscribe"
      )
    rescue ActiveRecord::RecordNotUnique
      UpstreamPushSubscription.live.find_by!(feed_id: feed.id, protocol: "websub", hub_url: hub_url, topic_url: topic_url)
    end

    def send_hub_request(sub, mode:)
      now = Time.current
      form = {
        "hub.mode" => mode,
        "hub.topic" => sub.topic_url,
        "hub.callback" => sub.callback_url
      }
      if mode == "subscribe"
        form["hub.secret"] = sub.secret if sub.secret.present?
        form["hub.lease_seconds"] = DEFAULT_LEASE_SECONDS.to_s
      end

      sub.update!(requested_mode: mode, last_requested_at: now)
      resp = @fetcher.post(sub.hub_url, body: URI.encode_www_form(form), content_type: "application/x-www-form-urlencoded")

      if resp.success?
        sub.update!(last_error: nil, next_renew_at: sub.next_renew_at || 1.hour.from_now)
        Result.new(status: :ok, subscription: sub, body: resp.body, content_type: resp.content_type, http_status: resp.status, error: nil)
      else
        record_hub_failure!(sub, "Hub returned HTTP #{resp.status}", now: now)
      end
    rescue Security::SafeHttpFetch::Error => e
      record_hub_failure!(sub, e.message, now: Time.current)
    end

    def record_hub_failure!(sub, message, now:)
      failures = sub.failure_count + 1
      backoff = [ 15.minutes * (2**(failures - 1)), 24.hours ].min
      sub.update!(
        status: sub.active? ? "active" : "error",
        failure_count: failures,
        last_error: message.to_s.truncate(1000),
        next_renew_at: now + backoff
      )
      Result.new(status: :error, subscription: sub, body: nil, content_type: nil, http_status: nil, error: message)
    end
  end
end
