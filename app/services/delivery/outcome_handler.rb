require "time"

module Delivery
  # Shared HTTP delivery outcome policy for outbound WebSub fat-push and rssCloud pings.
  module OutcomeHandler
    MAX_ATTEMPTS = 6
    MAX_BACKOFF = 1.hour
    SUSPEND_AFTER_FAILURES = 5
    SUSPEND_AFTER_4XX = 3

    module_function

    def record_response!(subscription:, attempt:, response:)
      now = Time.current
      code = response.status

      if code >= 200 && code < 300
        attempt.update!(status: "delivered", http_status: code, delivered_at: now, last_error: nil, next_attempt_at: nil)
        subscription.update!(failure_count: 0, last_delivered_at: now, last_error: nil)
        return :delivered
      end

      # 410 Gone disables/unsubscribes downstream destination immediately per spec Section 15.
      if code == 410
        attempt.update!(status: "failed", http_status: code, last_error: "Destination returned HTTP 410 Gone", next_attempt_at: nil)
        subscription.update!(status: "unsubscribed", last_error: "Destination returned HTTP 410 Gone")
        return :unsubscribed
      end

      if code == 408 || code == 429 || code >= 500
        return schedule_retry_or_fail!(
          subscription: subscription,
          attempt: attempt,
          http_status: code,
          error_message: "Destination returned HTTP #{code}",
          retry_after: response.retry_after,
          now: now
        )
      end

      # Permanent 4xx (or unexpected 3xx): do not retry endlessly.
      failures = subscription.failure_count + 1
      new_status = failures >= SUSPEND_AFTER_4XX ? "suspended" : subscription.status
      attempt.update!(status: "failed", http_status: code, last_error: "Permanent HTTP #{code}", next_attempt_at: nil)
      subscription.update!(status: new_status, failure_count: failures, last_error: "Permanent HTTP #{code}")
      :failed
    end

    def record_error!(subscription:, attempt:, error:, ssrf_blocked: false)
      now = Time.current
      if ssrf_blocked
        attempt.update!(status: "failed", http_status: 0, last_error: error.message.to_s.truncate(500), next_attempt_at: nil)
        subscription.update!(status: "suspended", failure_count: subscription.failure_count + 1, last_error: error.message.to_s.truncate(500))
        return :suspended
      end

      schedule_retry_or_fail!(
        subscription: subscription,
        attempt: attempt,
        http_status: 0,
        error_message: "#{error.class}: #{error.message}",
        retry_after: nil,
        now: now
      )
    end

    def schedule_retry_or_fail!(subscription:, attempt:, http_status:, error_message:, retry_after:, now:)
      msg = error_message.to_s.truncate(500)
      if attempt.attempt_number < MAX_ATTEMPTS
        delay = compute_backoff(attempt.attempt_number, retry_after, now)
        attempt.update!(status: "retry_scheduled", http_status: http_status, last_error: msg, next_attempt_at: now + delay)
        subscription.update!(last_error: msg)
        :retry_scheduled
      else
        failures = subscription.failure_count + 1
        new_status = failures >= SUSPEND_AFTER_FAILURES ? "suspended" : subscription.status
        attempt.update!(status: "failed", http_status: http_status, last_error: "Exhausted retries: #{msg}", next_attempt_at: nil)
        subscription.update!(status: new_status, failure_count: failures, last_error: msg)
        :failed
      end
    end

    def compute_backoff(attempt_number, retry_after, now)
      base = [ 30.seconds * (2**(attempt_number - 1)), MAX_BACKOFF ].min
      jittered = base * (0.8 + rand * 0.4)
      ra = parse_retry_after(retry_after, now)
      ra ? [ [ ra, jittered ].max, MAX_BACKOFF ].min : jittered
    end

    def parse_retry_after(header, now)
      return nil if header.blank?

      if header.strip.match?(/\A\d+\z/)
        [ header.to_i.seconds, MAX_BACKOFF ].min
      else
        delta = Time.httpdate(header.strip) - now
        delta > 0 ? [ delta, MAX_BACKOFF ].min : nil
      end
    rescue ArgumentError
      nil
    end
  end
end
