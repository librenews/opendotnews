module Feeds
  class Fetch
    Result = Data.define(:status, :ingest_result, :error)

    def self.call(feed, fetcher: nil, adapter: nil)
      new(feed, fetcher: fetcher, adapter: adapter).call
    end

    def initialize(feed, fetcher: nil, adapter: nil)
      @feed = feed
      @adapter = adapter || Sources::Registry.adapter_for(feed, fetcher: fetcher)
    end

    def call
      now = Time.current
      fetch_result = @adapter.fetch(@feed)

      if fetch_result.not_modified?
        @feed.update!(
          last_fetched_at: now,
          last_successful_fetch_at: now,
          last_http_status: fetch_result.http_status,
          last_fetch_duration_ms: fetch_result.duration_ms,
          last_ingestion_method: "poll",
          last_diagnostics: fetch_result.diagnostics,
          fetching_started_at: nil,
          fetch_failure_count: 0,
          last_error: nil,
          next_fetch_at: Feeds::Schedule.next_fetch_time(feed: @feed, response: fetch_result.response, failed: false, now: now)
        )
        return Result.new(status: :not_modified, ingest_result: nil, error: nil)
      end

      unless fetch_result.ok?
        return record_failure!(fetch_result, now: now)
      end

      record_redirect_aliases!(fetch_result.response)

      ingest_result = Feeds::Ingest.call(
        feed: @feed,
        normalized_items: fetch_result.items,
        source_attributes: fetch_result.source_attributes,
        source_metadata: fetch_result.source_metadata,
        raw_body: fetch_result.raw_body,
        etag: fetch_result.etag,
        last_modified: fetch_result.last_modified,
        ingestion_method: "poll",
        http_status: fetch_result.http_status,
        duration_ms: fetch_result.duration_ms,
        diagnostics: fetch_result.diagnostics
      )

      @feed.reload
      @feed.update!(
        fetching_started_at: nil,
        next_fetch_at: Feeds::Schedule.next_fetch_time(feed: @feed, response: fetch_result.response, failed: false, now: now)
      )

      Result.new(status: :ok, ingest_result: ingest_result, error: nil)
    rescue StandardError => e
      record_exception!(e, now: Time.current)
    end

    private

    def record_failure!(fetch_result, now:)
      next_failures = @feed.fetch_failure_count + 1
      @feed.fetch_failure_count = next_failures
      @feed.update!(
        last_fetched_at: now,
        last_error_at: now,
        last_http_status: fetch_result.http_status,
        last_fetch_duration_ms: fetch_result.duration_ms,
        last_ingestion_method: "poll",
        last_diagnostics: (fetch_result.diagnostics || {}).merge("failed" => true),
        fetching_started_at: nil,
        fetch_failure_count: next_failures,
        last_error: fetch_result.error.to_s.truncate(1000),
        status: next_failures >= 5 ? "error" : @feed.status,
        next_fetch_at: Feeds::Schedule.next_fetch_time(feed: @feed, response: fetch_result.response, failed: true, now: now)
      )
      Result.new(status: :error, ingest_result: nil, error: fetch_result.error)
    end

    def record_exception!(err, now:)
      next_failures = @feed.fetch_failure_count + 1
      @feed.fetch_failure_count = next_failures
      @feed.update!(
        last_fetched_at: now,
        last_error_at: now,
        last_http_status: 0,
        last_ingestion_method: "poll",
        last_diagnostics: { "error_class" => err.class.name, "failed" => true },
        fetching_started_at: nil,
        fetch_failure_count: next_failures,
        last_error: err.message.to_s.truncate(1000),
        status: next_failures >= 5 ? "error" : @feed.status,
        next_fetch_at: Feeds::Schedule.next_fetch_time(feed: @feed, response: nil, failed: true, now: now)
      )
      Result.new(status: :error, ingest_result: nil, error: err.message)
    end

    def record_redirect_aliases!(resp)
      return if resp.nil? || resp.redirect_chain.empty?

      resp.redirect_chain.each do |old_url|
        norm = UrlNormalizer.normalize(old_url)
        next if norm.blank? || norm == @feed.canonical_url

        FeedAlias.find_or_create_by!(url: norm) do |a|
          a.feed = @feed
          a.reason = "redirect"
        end
      rescue ActiveRecord::RecordNotUnique
        nil
      end
    end
  end
end
