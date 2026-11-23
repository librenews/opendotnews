require "digest"

module Feeds
  class Ingest
    Result = Data.define(:status, :created_count, :updated_count, :unchanged_count)

    def self.call(
      feed:,
      parsed_feed: nil,
      normalized_items: nil,
      source_attributes: {},
      source_metadata: {},
      raw_body: nil,
      etag: nil,
      last_modified: nil,
      ingestion_method: "poll",
      http_status: nil,
      duration_ms: nil,
      diagnostics: {}
    )
      new(
        feed: feed,
        parsed_feed: parsed_feed,
        normalized_items: normalized_items,
        source_attributes: source_attributes,
        source_metadata: source_metadata,
        raw_body: raw_body,
        etag: etag,
        last_modified: last_modified,
        ingestion_method: ingestion_method,
        http_status: http_status,
        duration_ms: duration_ms,
        diagnostics: diagnostics
      ).call
    end

    def initialize(
      feed:,
      parsed_feed: nil,
      normalized_items: nil,
      source_attributes: {},
      source_metadata: {},
      raw_body: nil,
      etag: nil,
      last_modified: nil,
      ingestion_method: "poll",
      http_status: nil,
      duration_ms: nil,
      diagnostics: {}
    )
      @feed = feed
      @parsed_feed = parsed_feed
      @normalized_items = normalized_items
      @source_attributes = (source_attributes || {}).symbolize_keys
      @source_metadata = source_metadata || {}
      @raw_body = raw_body
      @etag = etag
      @last_modified = last_modified
      @ingestion_method = ingestion_method.to_s.presence || "poll"
      @http_status = http_status
      @duration_ms = duration_ms
      @diagnostics = diagnostics || {}
    end

    def call
      items = resolve_normalized_items
      attrs = resolve_source_attributes
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

        existing_by_ext_id = if items.any?
          FeedItem.where(feed_id: @feed.id, external_id: items.map(&:external_id)).index_by(&:external_id)
        else
          {}
        end

        items.each do |norm|
          existing = existing_by_ext_id[norm.external_id] || find_fallback_match(norm)
          if existing.nil?
            outcome = create_item_idempotently!(norm, now)
            if outcome == :created
              created += 1
            elsif outcome == :updated
              updated += 1
            else
              unchanged += 1
            end
          elsif existing.content_hash != norm.content_hash || existing.external_id != norm.external_id
            update_item!(existing, norm, now)
            updated += 1
          else
            existing.update_columns(last_seen_at: now)
            unchanged += 1
          end
        end

        feed_changed = created > 0 || updated > 0 || (feed_hash.present? && @feed.content_hash != feed_hash)
        merged_metadata = (@feed.source_metadata || {}).merge(@source_metadata.stringify_keys)
        merged_diagnostics = @diagnostics.stringify_keys.merge(
          "created_count" => created,
          "updated_count" => updated,
          "unchanged_count" => unchanged,
          "ingestion_method" => @ingestion_method
        )

        @feed.update!(
          title: attrs[:title].presence || @feed.title,
          description: attrs[:description].presence || @feed.description,
          site_url: attrs[:site_url].presence || @feed.site_url,
          format: attrs[:format].presence || @feed.format,
          etag: @etag.nil? ? @feed.etag : @etag,
          last_modified: @last_modified.nil? ? @feed.last_modified : @last_modified,
          content_hash: feed_hash || @feed.content_hash,
          discovered_websub_hub: attrs[:discovered_websub_hub].presence || @feed.discovered_websub_hub,
          discovered_websub_topic: attrs[:discovered_websub_topic].presence || @feed.discovered_websub_topic,
          discovered_rsscloud_endpoint: attrs[:discovered_rsscloud_endpoint].presence || @feed.discovered_rsscloud_endpoint,
          discovered_rsscloud_protocol: attrs[:discovered_rsscloud_protocol].presence || @feed.discovered_rsscloud_protocol,
          source_metadata: merged_metadata,
          last_fetched_at: now,
          last_successful_fetch_at: now,
          last_changed_at: feed_changed ? now : @feed.last_changed_at,
          last_http_status: @http_status || @feed.last_http_status,
          last_fetch_duration_ms: @duration_ms || @feed.last_fetch_duration_ms,
          last_ingestion_method: @ingestion_method,
          last_diagnostics: merged_diagnostics,
          fetching_started_at: nil,
          fetch_failure_count: 0,
          last_error: nil,
          status: "active"
        )
      end

      Result.new(status: :ok, created_count: created, updated_count: updated, unchanged_count: unchanged)
    ensure
      maybe_enqueue_upstream_push!
    end

    private

    def maybe_enqueue_upstream_push!
      return unless @feed.discovered_websub_hub.present? || @feed.discovered_rsscloud_endpoint.present?
      return if @feed.active_subscriber_count == 0
      return if @feed.upstream_push_subscriptions.live.exists?

      Push::RegisterUpstreamJob.perform_async(@feed.id)
    rescue StandardError => e
      Rails.logger.warn("Skipping upstream push enqueue for feed #{@feed.id}: #{e.class}: #{e.message}")
    end

    def resolve_normalized_items
      raw_list = if !@normalized_items.nil?
        @normalized_items
      elsif @parsed_feed
        Feeds::Normalize.call(@parsed_feed, feed_url: @feed.canonical_url)
      else
        []
      end

      seen = {}
      raw_list.each_with_object([]) do |item, acc|
        next if item.nil? || seen[item.external_id]

        seen[item.external_id] = true
        acc << item
      end
    end

    def resolve_source_attributes
      return @source_attributes if @parsed_feed.nil?

      {
        title: @parsed_feed.title,
        description: @parsed_feed.description,
        site_url: @parsed_feed.site_url,
        format: @parsed_feed.format,
        discovered_websub_hub: @parsed_feed.websub_hub,
        discovered_websub_topic: @parsed_feed.websub_topic,
        discovered_rsscloud_endpoint: @parsed_feed.rsscloud_endpoint,
        discovered_rsscloud_protocol: @parsed_feed.rsscloud_protocol
      }.merge(@source_attributes)
    end

    # If a previously ingested item only had a deterministic fallback ID, and the source now
    # provides a real GUID/Atom ID with the same canonical permalink, promote it instead of duplicating.
    def find_fallback_match(norm)
      return nil if norm.external_url.blank? || norm.external_id.start_with?("fallback:")

      FeedItem.where(feed_id: @feed.id, external_url: norm.external_url)
        .where("external_id LIKE 'fallback:%'")
        .first
    end

    # PostgreSQL transaction-scoped advisory lock prevents overlapping poll + push ingestion races
    # and is automatically released on commit, rollback, or process crash.
    def acquire_feed_lock!(feed_id)
      sql = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_xact_lock(hashtext(?))", "feed:#{feed_id}" ])
      ActiveRecord::Base.connection.select_value(sql) == true
    end

    # Guard against concurrent uniqueness races using a savepoint so PostgreSQL transactions never abort.
    def create_item_idempotently!(norm, now)
      ActiveRecord::Base.transaction(requires_new: true) do
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
          current_revision_number: 1,
          metadata: norm.respond_to?(:metadata) ? (norm.metadata || {}) : {}
        )

        FeedItemRevision.create!(
          feed_item: item,
          revision_number: 1,
          content_hash: norm.content_hash,
          payload_snapshot: snapshot_for(norm),
          recorded_at: now
        )

        record_outbox_idempotently!(
          event_type: "feed_item.created",
          item: item,
          version: 1,
          now: now
        )
        :created
      end
    rescue ActiveRecord::RecordNotUnique
      existing = FeedItem.find_by!(feed_id: @feed.id, external_id: norm.external_id)
      if existing.content_hash != norm.content_hash
        update_item!(existing, norm, now)
        :updated
      else
        existing.update_columns(last_seen_at: now)
        :unchanged
      end
    end

    def update_item!(existing, norm, now)
      content_changed = (existing.content_hash != norm.content_hash)
      next_rev = content_changed ? existing.current_revision_number + 1 : existing.current_revision_number
      merged_meta = (existing.metadata || {}).merge(norm.respond_to?(:metadata) ? (norm.metadata || {}) : {})

      # Preserve historical first_seen_at and original published_at when already known.
      existing.update!(
        external_id: norm.external_id,
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
        current_revision_number: next_rev,
        metadata: merged_meta
      )

      return unless content_changed

      ActiveRecord::Base.transaction(requires_new: true) do
        FeedItemRevision.create!(
          feed_item: existing,
          revision_number: next_rev,
          content_hash: norm.content_hash,
          payload_snapshot: snapshot_for(norm),
          recorded_at: now
        )
      rescue ActiveRecord::RecordNotUnique
        nil
      end

      record_outbox_idempotently!(
        event_type: "feed_item.updated",
        item: existing,
        version: next_rev,
        now: now
      )
    end

    def record_outbox_idempotently!(event_type:, item:, version:, now:)
      ActiveRecord::Base.transaction(requires_new: true) do
        OutboxEvent.create!(
          event_type: event_type,
          aggregate_type: "FeedItem",
          aggregate_id: item.id,
          aggregate_version: version,
          payload: { "feed_id" => @feed.id, "feed_item_id" => item.id, "revision_number" => version },
          created_at: now
        )
      rescue ActiveRecord::RecordNotUnique
        nil
      end
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
