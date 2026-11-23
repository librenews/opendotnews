module Subscriptions
  class Subscribe
    Result = Data.define(:status, :subscription, :feed, :already_subscribed, :candidates, :error_code, :error) do
      def ok?
        status == :ok
      end

      def selection_required?
        status == :selection_required
      end
    end

    def self.call(user:, url:, folder: nil, fetcher: nil, enqueue_fetch: true)
      new(user: user, url: url, folder: folder, fetcher: fetcher, enqueue_fetch: enqueue_fetch).call
    end

    def initialize(user:, url:, folder: nil, fetcher: nil, enqueue_fetch: true)
      @user = user
      @raw_url = url.to_s.strip
      @folder = folder.to_s.strip.presence
      @fetcher = fetcher
      @enqueue_fetch = enqueue_fetch
    end

    def call
      norm_input = Feeds::UrlNormalizer.normalize(@raw_url)
      unless norm_input
        return error_result("invalid_url", "URL must be a valid http(s) URL")
      end

      # Fast path: reuse already-known canonical feed or alias without extra upstream fetch.
      existing_feed = find_existing_feed(norm_input)
      if existing_feed
        sub, already = attach_subscription!(existing_feed)
        if @enqueue_fetch && existing_feed.last_fetched_at.nil?
          Feeds::FetchJob.perform_async(existing_feed.id)
        end
        return Result.new(
          status: :ok,
          subscription: sub,
          feed: existing_feed,
          already_subscribed: already,
          candidates: [],
          error_code: nil,
          error: nil
        )
      end

      # Discover feed from input URL (direct feed or HTML autodiscovery).
      disc = Feeds::Discover.call(norm_input, fetcher: @fetcher)
      if disc.selection_required?
        return Result.new(
          status: :selection_required,
          subscription: nil,
          feed: nil,
          already_subscribed: false,
          candidates: disc.candidates,
          error_code: "ambiguous_feed",
          error: "Multiple feeds advertised at URL; choose one feed URL"
        )
      end

      unless disc.found?
        code = disc.status == :not_found ? "feed_not_found" : "invalid_url"
        return error_result(code, disc.error || "Unable to discover feed")
      end

      feed = find_or_create_feed!(disc.canonical_url, disc.parsed_feed)
      record_aliases!(feed, norm_input, disc)
      sub, already = attach_subscription!(feed)

      # Ingest the already-fetched feed body directly (no duplicate initial HTTP request!).
      if disc.parsed_feed && disc.response
        Feeds::Ingest.call(
          feed: feed,
          parsed_feed: disc.parsed_feed,
          raw_body: disc.response.body,
          etag: disc.response.etag,
          last_modified: disc.response.last_modified,
          ingestion_method: "discover",
          http_status: disc.response.status
        )
        feed.reload
        feed.update!(next_fetch_at: Feeds::Schedule.next_fetch_time(feed: feed, response: disc.response, failed: false))
      elsif @enqueue_fetch
        Feeds::FetchJob.perform_async(feed.id)
      end

      AuditLog.record!(
        action: "feed.subscribed",
        user: @user,
        resource_type: "Feed",
        resource_id: feed.id,
        scope: "feeds:write",
        metadata: { canonical_url: feed.canonical_url, already_subscribed: already }
      )

      Result.new(
        status: :ok,
        subscription: sub,
        feed: feed,
        already_subscribed: already,
        candidates: [],
        error_code: nil,
        error: nil
      )
    end

    private

    def find_existing_feed(norm_url)
      Feed.find_by(canonical_url: norm_url) || FeedAlias.find_by(url: norm_url)&.feed
    end

    def find_or_create_feed!(canonical_url, parsed)
      Feed.find_or_create_by!(canonical_url: canonical_url) do |f|
        f.title = parsed&.title
        f.description = parsed&.description
        f.site_url = parsed&.site_url
        f.format = parsed&.format
        f.status = "active"
        f.next_fetch_at = Time.current
      end
    rescue ActiveRecord::RecordNotUnique
      Feed.find_by!(canonical_url: canonical_url)
    end

    def record_aliases!(feed, norm_input, disc)
      aliases = []
      aliases << [ norm_input, "input" ] if norm_input != feed.canonical_url
      disc.response&.redirect_chain&.each do |u|
        n = Feeds::UrlNormalizer.normalize(u)
        aliases << [ n, "redirect" ] if n.present? && n != feed.canonical_url
      end
      if disc.response && (n = Feeds::UrlNormalizer.normalize(disc.response.final_url)) && n != feed.canonical_url
        aliases << [ n, "discovery" ]
      end

      aliases.uniq(&:first).each do |url, reason|
        FeedAlias.find_or_create_by!(url: url) do |a|
          a.feed = feed
          a.reason = reason
        end
      rescue ActiveRecord::RecordNotUnique
        nil
      end
    end

    def attach_subscription!(feed)
      existing = UserFeedSubscription.active.find_by(user_id: @user.id, feed_id: feed.id)
      if existing
        existing.update!(folder_name: @folder) if @folder.present? && existing.folder_name != @folder
        return [ existing, true ]
      end

      sub = UserFeedSubscription.create!(
        user: @user,
        feed: feed,
        folder_name: @folder,
        subscribed_at: Time.current
      )
      [ sub, false ]
    rescue ActiveRecord::RecordNotUnique
      [ UserFeedSubscription.active.find_by!(user_id: @user.id, feed_id: feed.id), true ]
    end

    def error_result(code, message)
      Result.new(
        status: :error,
        subscription: nil,
        feed: nil,
        already_subscribed: false,
        candidates: [],
        error_code: code,
        error: message
      )
    end
  end
end
