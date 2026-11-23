require "time"

module Feeds
  class Schedule
    MAX_BACKOFF = 24.hours
    IDLE_INTERVAL = 6.hours

    def self.next_fetch_time(feed:, response: nil, failed: false, now: Time.current)
      new(feed: feed, response: response, failed: failed, now: now).next_fetch_time
    end

    def self.enqueue_due!(limit: 200, now: Time.current)
      enqueued = 0
      Feed.due_for_fetch(now).order(next_fetch_at: :asc).limit(limit).find_each do |feed|
        # Claim fetch slot atomically so concurrent schedulers do not double-enqueue.
        claimed = Feed.where(id: feed.id)
          .where("fetching_started_at IS NULL OR fetching_started_at < ?", now - 5.minutes)
          .update_all(fetching_started_at: now)
        next if claimed == 0

        Feeds::FetchJob.perform_async(feed.id)
        enqueued += 1
      end
      enqueued
    end

    def initialize(feed:, response:, failed:, now:)
      @feed = feed
      @response = response
      @failed = failed
      @now = now
    end

    def next_fetch_time
      if @failed
        failures = [ @feed.fetch_failure_count, 1 ].max
        delay = [ OpenNews.config.feed_poll_interval * (2**(failures - 1)), MAX_BACKOFF ].min
        retry_after = parse_retry_after(@response&.retry_after)
        delay = [ delay, retry_after ].max if retry_after
        return @now + apply_jitter(delay)
      end

      # Reduce polling frequency when a feed has zero active subscribers.
      base = if @feed.active_subscriber_count == 0
        IDLE_INTERVAL
      else
        OpenNews.config.feed_poll_interval
      end

      cache_max_age = parse_cache_max_age(@response&.cache_control)
      interval = cache_max_age ? [ [ cache_max_age, base ].max, MAX_BACKOFF ].min : base
      @now + apply_jitter(interval)
    end

    private

    def parse_retry_after(header)
      return nil if header.blank?

      if header.strip.match?(/\A\d+\z/)
        [ header.to_i.seconds, MAX_BACKOFF ].min
      else
        t = Time.httpdate(header.strip)
        delta = t - @now
        delta > 0 ? [ delta, MAX_BACKOFF ].min : nil
      end
    rescue ArgumentError
      nil
    end

    def parse_cache_max_age(header)
      return nil if header.blank?

      if (m = header.match(/max-age\s*=\s*(\d+)/i))
        m[1].to_i.seconds
      end
    end

    def apply_jitter(duration)
      # +/- 10% jitter to avoid thundering herds
      factor = 0.9 + (rand * 0.2)
      duration * factor
    end
  end
end
