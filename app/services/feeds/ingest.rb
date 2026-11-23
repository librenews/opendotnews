require "digest"

module Feeds
  class Ingest
    Result = Data.define(:status, :created_count, :updated_count, :unchanged_count)

    def self.call(feed:, parsed_feed:, raw_body: nil, etag: nil, last_modified: nil)
      new(feed: feed, parsed_feed: parsed_feed, raw_body: raw_body, etag: etag, last_modified: last_modified).call
    end

    def initialize(feed:, parsed_feed:, raw_body: nil, etag: nil, last_modified: nil)
      @feed = feed
      @parsed_feed = parsed_feed
      @raw_body = raw_body
      @etag = etag
      @last_modified = last_modified
    end

    def call
      normalized_items = Feeds::Normalize.call(@parsed_feed, feed_url: @feed.canonical_url)
      now = Time.current
      feed_hash = @raw_body ? Digest::SHA256.hexdigest(@raw_body.to_s) : nil

      created = 0
      updated = 0
      unchanged = 0

      ActiveRecord::Base.transaction do
        unless acquire_feed_lock!(@feed.id)
          return Result.new(status: :locked, created_count: 0, updated_count: 0, unchanged_count: 0)
        end

        @feed.reload

        existing_by_ext_id = if normalized_items.any?
          FeedItem.where(feed_id: @feed.id, external_id: normalized_items.map(&:external_id)).index_by(&:external_id)
        else
          {}
        end

        normalized_items.each do |norm|
          existing = existing_by_ext_id[norm.external_id]
          if existing.nil?
            create_item!(norm, now)
            created += 1
          elsif existing.content_hash != norm.content_hash
            update_item!(existing, norm, now)
            updated += 1
          else
            existing.update_columns(last_seen_at: now)
            unchanged += 1
          end
        end

        feed_changed = created > 0 || updated > 0 || (feed_hash.present? && @feed.content_hash != feed_hash)

        @feed.update!(
          title: @parsed_feed.title.presence || @feed.title,
          description: @parsed_feed.description.presence || @feed.description,
          site_url: @parsed_feed.site_url.presence || @feed.site_url,
          format: @parsed_feed.format.presence || @feed.format,
          etag: @etag.nil? ? @feed.etag : @etag,
          last_modified: @last_modified.nil? ? @feed.last_modified : @last_modified,
          content_hash: feed_hash || @feed.content_hash,
          discovered_websub_hub: @parsed_feed.websub_hub.presence || @feed.discovered_websub_hub,
          discovered_websub_topic: @parsed_feed.websub_topic.presence || @feed.discovered_websub_topic,
          discovered_rsscloud_endpoint: @parsed_feed.rsscloud_endpoint.presence || @feed.discovered_rsscloud_endpoint,
          discovered_rsscloud_protocol: @parsed_feed.rsscloud_protocol.presence || @feed.discovered_rsscloud_protocol,
          last_fetched_at: now,
          last_changed_at: feed_changed ? now : @feed.last_changed_at,
          fetching_started_at: nil,
          fetch_failure_count: 0,
          last_error: nil,
          status: "active"
        )
      end

      Result.new(status: :ok, created_count: created, updated_count: updated, unchanged_count: unchanged)
    end

    private

    # PostgreSQL transaction-scoped advisory lock prevents overlapping poll + push ingestion races
    # and is automatically released on commit, rollback, or process crash.
    def acquire_feed_lock!(feed_id)
      sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_xact_lock(hashtext(?))", "feed:#{feed_id}" ])
      ActiveRecord::Base.connection.select_value(sql) == true
    end

    def create_item!(norm, now)
      item = FeedItem.create!(
        feed: @feed,
        external_id: norm.external_id,
        external_url: norm.external_url,
        title: norm.title,
        author: norm.author,
        summary_text: norm.summary_text,
        content_html_sanitized: norm.content_html_sanitized,
        content_text: norm.content_text,
        published_at: norm.published_at,
        source_updated_at: norm.source_updated_at,
        first_seen_at: now,
        last_seen_at: now,
        content_hash: norm.content_hash,
        current_revision_number: 1
      )

      FeedItemRevision.create!(
        feed_item: item,
        revision_number: 1,
        content_hash: norm.content_hash,
        payload_snapshot: snapshot_for(norm),
        recorded_at: now
      )

      OutboxEvent.create!(
        event_type: "feed_item.created",
        aggregate_type: "FeedItem",
        aggregate_id: item.id,
        aggregate_version: 1,
        payload: { "feed_id" => @feed.id, "feed_item_id" => item.id, "revision_number" => 1 },
        created_at: now
      )
    end

    def update_item!(existing, norm, now)
      next_rev = existing.current_revision_number + 1

      # Preserve historical first_seen_at and original published_at when already known.
      existing.update!(
        external_url: norm.external_url.presence || existing.external_url,
        title: norm.title.presence || existing.title,
        author: norm.author.presence || existing.author,
        summary_text: norm.summary_text,
        content_html_sanitized: norm.content_html_sanitized,
        content_text: norm.content_text,
        published_at: existing.published_at || norm.published_at,
        source_updated_at: norm.source_updated_at || now,
        last_seen_at: now,
        content_hash: norm.content_hash,
        current_revision_number: next_rev
      )

      FeedItemRevision.create!(
        feed_item: existing,
        revision_number: next_rev,
        content_hash: norm.content_hash,
        payload_snapshot: snapshot_for(norm),
        recorded_at: now
      )

      OutboxEvent.create!(
        event_type: "feed_item.updated",
        aggregate_type: "FeedItem",
        aggregate_id: existing.id,
        aggregate_version: next_rev,
        payload: { "feed_id" => @feed.id, "feed_item_id" => existing.id, "revision_number" => next_rev },
        created_at: now
      )
    end

    def snapshot_for(norm)
      {
        "title" => norm.title,
        "external_url" => norm.external_url,
        "author" => norm.author,
        "summary_text" => norm.summary_text.to_s.truncate(1000)
      }
    end
  end
end
