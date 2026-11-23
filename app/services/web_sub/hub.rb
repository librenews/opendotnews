require "openssl"
require "digest"
require "uri"

module WebSub
  # W3C WebSub Hub serving public hosted RSS/Atom feeds owned by this Open.News instance.
  class Hub
    MIN_LEASE_SECONDS = 60
    DEFAULT_LEASE_SECONDS = 5.days.to_i
    MAX_LEASE_SECONDS = 10.days.to_i
    MAX_SECRET_BYTES = 199 # W3C WebSub Section 5.1: MUST be less than 200 bytes

    Result = Data.define(:status, :subscription, :http_status, :error) do
      def ok?
        status == :ok
      end
    end

    def self.handle_request(params:, verify_async: true, fetcher: nil)
      new(fetcher: fetcher).handle_request(params: params, verify_async: verify_async)
    end

    def self.verify_subscription!(subscription, mode:, challenge:, lease_seconds: nil, fetcher: nil)
      new(fetcher: fetcher).verify_subscription!(subscription, mode: mode, challenge: challenge, lease_seconds: lease_seconds)
    end

    def self.deliver!(subscription:, outbox_event:, attempt_number: 1, fetcher: nil)
      new(fetcher: fetcher).deliver!(subscription: subscription, outbox_event: outbox_event, attempt_number: attempt_number)
    end

    def initialize(fetcher: nil)
      @fetcher = fetcher || Security::SafeHttpFetch.new
    end

    def handle_request(params:, verify_async: true)
      mode = params["hub.mode"].to_s.strip
      unless %w[subscribe unsubscribe].include?(mode)
        return Result.new(status: :bad_request, subscription: nil, http_status: 400, error: "hub.mode must be 'subscribe' or 'unsubscribe'")
      end

      resolved = Publishing::HostedTopicResolver.resolve(params["hub.topic"])
      unless resolved
        return Result.new(status: :bad_request, subscription: nil, http_status: 400, error: "hub.topic is not a public hosted feed on this instance")
      end

      callback_url = Feeds::UrlNormalizer.normalize(params["hub.callback"])
      unless callback_url
        return Result.new(status: :bad_request, subscription: nil, http_status: 400, error: "hub.callback must be a valid http(s) URL")
      end

      cb_uri = URI.parse(callback_url)
      bare_host = cb_uri.host.to_s.delete_prefix("[").delete_suffix("]")
      if !OpenNews.config.allow_private_http_fetch &&
         (bare_host == "localhost" || ((IPAddr.new(bare_host) && Security::SafeHttpFetch.blocked_ip?(bare_host)) rescue false))
        return Result.new(status: :bad_request, subscription: nil, http_status: 400, error: "hub.callback destination is disallowed by SSRF policy")
      end

      secret = params["hub.secret"].to_s.presence
      if secret && secret.bytesize > MAX_SECRET_BYTES
        return Result.new(status: :bad_request, subscription: nil, http_status: 400, error: "hub.secret must be less than 200 bytes")
      end

      requested_lease = params["hub.lease_seconds"].to_i
      lease_seconds = requested_lease > 0 ? requested_lease.clamp(MIN_LEASE_SECONDS, MAX_LEASE_SECONDS) : DEFAULT_LEASE_SECONDS

      sub = find_or_prepare_subscription(resolved, callback_url, cb_uri.host, mode: mode, secret: secret, lease_seconds: lease_seconds)
      return Result.new(status: :ok, subscription: nil, http_status: 202, error: nil) if sub.nil? && mode == "unsubscribe"

      challenge = SecureRandom.urlsafe_base64(32)
      sub.update!(
        verification_challenge_digest: Digest::SHA256.hexdigest(challenge),
        verification_expires_at: 10.minutes.from_now
      )

      if verify_async
        WebSub::VerifySubscriptionJob.perform_async(sub.id, mode, challenge, lease_seconds)
      else
        verify_subscription!(sub, mode: mode, challenge: challenge, lease_seconds: lease_seconds)
      end

      Result.new(status: :ok, subscription: sub, http_status: 202, error: nil)
    end

    # W3C WebSub Section 5.3 — Hub verifies subscriber intent via GET challenge before activation.
    def verify_subscription!(subscription, mode:, challenge:, lease_seconds: nil)
      expected_digest = Digest::SHA256.hexdigest(challenge.to_s)
      if subscription.verification_challenge_digest != expected_digest ||
         (subscription.verification_expires_at && subscription.verification_expires_at < Time.current)
        return :expired_challenge
      end

      lease = (lease_seconds || subscription.lease_seconds || DEFAULT_LEASE_SECONDS).to_i.clamp(MIN_LEASE_SECONDS, MAX_LEASE_SECONDS)
      verify_url = build_verification_url(subscription.callback_url, mode: mode, topic: subscription.topic_url, challenge: challenge, lease_seconds: lease)

      resp = @fetcher.get(verify_url)
      if resp.success? && resp.body.to_s == challenge.to_s
        now = Time.current
        if mode == "subscribe"
          subscription.update!(
            status: "active",
            lease_seconds: lease,
            lease_expires_at: now + lease.seconds,
            verification_challenge_digest: nil,
            verification_expires_at: nil,
            failure_count: 0,
            last_error: nil
          )
          return :verified
        else
          subscription.update!(
            status: "unsubscribed",
            lease_expires_at: nil,
            verification_challenge_digest: nil,
            verification_expires_at: nil,
            last_error: nil
          )
          return :unsubscribed
        end
      end

      subscription.update!(
        status: subscription.active? ? "active" : "expired",
        last_error: "Verification failed (HTTP #{resp.status})",
        verification_challenge_digest: nil
      )
      :rejected
    rescue Security::SafeHttpFetch::Error => e
      subscription.update!(
        status: subscription.active? ? "active" : "expired",
        last_error: "Verification error: #{e.message.to_s.truncate(400)}",
        verification_challenge_digest: nil
      )
      :error
    end

    # W3C WebSub Section 7 — Fat push delivering the full RSS/Atom feed representation + HMAC-SHA256.
    def deliver!(subscription:, outbox_event:, attempt_number: 1)
      return :inactive unless subscription.active?

      attempt = find_or_create_attempt!(subscription, outbox_event, attempt_number)
      return :already_delivered if attempt.status == "delivered"

      payload = if subscription.topic_format == "atom"
        Publishing::Syndicate.to_atom(subscription.publication)
      else
        Publishing::Syndicate.to_rss(subscription.publication)
      end

      headers = { "Link" => payload.link_header }
      if subscription.secret.present?
        sig = OpenSSL::HMAC.hexdigest("SHA256", subscription.secret, payload.xml)
        headers["X-Hub-Signature"] = "sha256=#{sig}"
      end

      resp = @fetcher.post(
        subscription.callback_url,
        body: payload.xml,
        content_type: payload.content_type,
        headers: headers
      )

      Delivery::OutcomeHandler.record_response!(subscription: subscription, attempt: attempt, response: resp)
    rescue Security::SafeHttpFetch::SsrfBlockedError => e
      Delivery::OutcomeHandler.record_error!(subscription: subscription, attempt: attempt, error: e, ssrf_blocked: true)
    rescue Security::SafeHttpFetch::Error => e
      Delivery::OutcomeHandler.record_error!(subscription: subscription, attempt: attempt, error: e)
    end

    private

    def find_or_prepare_subscription(resolved, callback_url, callback_host, mode:, secret:, lease_seconds:)
      existing = DownstreamSubscription.find_by(
        protocol: "websub",
        topic_url: resolved.canonical_topic_url,
        callback_url: callback_url
      )

      if mode == "unsubscribe"
        return existing
      end

      if existing
        existing.update!(
          publication: resolved.publication,
          topic_format: resolved.format,
          callback_host: callback_host.downcase,
          secret: secret,
          lease_seconds: lease_seconds,
          status: existing.active? ? "active" : "pending"
        )
        existing
      else
        DownstreamSubscription.create!(
          publication: resolved.publication,
          protocol: "websub",
          topic_url: resolved.canonical_topic_url,
          topic_format: resolved.format,
          callback_url: callback_url,
          callback_host: callback_host.downcase,
          secret: secret,
          lease_seconds: lease_seconds,
          status: "pending"
        )
      end
    rescue ActiveRecord::RecordNotUnique
      DownstreamSubscription.find_by!(protocol: "websub", topic_url: resolved.canonical_topic_url, callback_url: callback_url)
    end

    def build_verification_url(callback_url, mode:, topic:, challenge:, lease_seconds:)
      uri = URI.parse(callback_url)
      existing_params = URI.decode_www_form(uri.query.to_s)
      extra = [
        [ "hub.mode", mode ],
        [ "hub.topic", topic ],
        [ "hub.challenge", challenge ]
      ]
      extra << [ "hub.lease_seconds", lease_seconds.to_s ] if mode == "subscribe"
      uri.query = URI.encode_www_form(existing_params + extra)
      uri.to_s
    end

    def find_or_create_attempt!(subscription, outbox_event, attempt_number)
      DeliveryAttempt.find_or_create_by!(
        downstream_subscription: subscription,
        outbox_event: outbox_event,
        attempt_number: attempt_number
      ) do |a|
        a.status = "pending"
      end
    rescue ActiveRecord::RecordNotUnique
      DeliveryAttempt.find_by!(
        downstream_subscription: subscription,
        outbox_event: outbox_event,
        attempt_number: attempt_number
      )
    end
  end
end
