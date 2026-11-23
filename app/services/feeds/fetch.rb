module Feeds
  class Fetch
    Result = Data.define(:status, :ingest_result, :error)

    def self.call(feed, fetcher: nil)
      new(feed, fetcher: fetcher).call
    end

    def initialize(feed, fetcher: nil)
      @feed = feed
      @fetcher = fetcher || Security::SafeHttpFetch.new
    end

    def call
      now = Time.current
      resp = @fetcher.get(@feed.canonical_url, etag: @feed.etag, last_modified: @feed.last_modified)

      if resp.not_modified?
        @feed.update!(
          last_fetched_at: now,
          fetching_started_at: nil,
          fetch_failure_count: 0,
          last_error: nil,
          next_fetch_at: Feeds::Schedule.next_fetch_time(feed: @feed, response: resp, failed: false, now: now)
        )
        return Result.new(status: :not_modified, ingest_result: nil, error: nil)
      end

      unless resp.success?
        return record_failure!("HTTP #{resp.status}", response: resp, now: now)
      end

      record_redirect_aliases!(resp)

      parsed = Feeds::Parse.call(resp.body, headers: resp.headers, base_url: resp.final_url)
      ingest_result = Feeds::Ingest.call(
        feed: @feed,
        parsed_feed: parsed,
        raw_body: resp.body,
        etag: resp.etag,
        last_modified: resp.last_modified
      )

      @feed.reload
      @feed.update!(
        fetching_started_at: nil,
        next_fetch_at: Feeds::Schedule.next_fetch_time(feed: @feed, response: resp, failed: false, now: now)
      )

      Result.new(status: :ok, ingest_result: ingest_result, error: nil)
    rescue Feeds::Parse::ParseError, Security::SafeHttpFetch::Error => e
      record_failure!(e.message, response: nil, now: Time.current)
    end

    private

    def record_failure!(message, response:, now:)
      next_failures = @feed.fetch_failure_count + 1
      @feed.fetch_failure_count = next_failures
      @feed.update!(
        last_fetched_at: now,
        fetching_started_at: nil,
        fetch_failure_count: next_failures,
        last_error: message.to_s.truncate(1000),
        status: next_failures >= 5 ? "error" : @feed.status,
        next_fetch_at: Feeds::Schedule.next_fetch_time(feed: @feed, response: response, failed: true, now: now)
      )
      Result.new(status: :error, ingest_result: nil, error: message)
    end

    def record_redirect_aliases!(resp)
      return if resp.redirect_chain.empty?

      resp.redirect_chain.each do |old_url|
        norm = UrlNormalizer.normalize(old_url)
        next if norm.blank? || norm == @feed.canonical_url

        FeedAlias.find_or_create_by!(url: norm) do |a|
          a.feed = @feed
          a.reason = "redirect"
        end
      rescue ActiveRecord::RecordNotUnique
        # Another worker recorded the alias concurrently.
      end
    end
  end
end
