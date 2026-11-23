require "base64"

module Search
  class Items
    MAX_LIMIT = 100
    DEFAULT_LIMIT = 25
    MAX_QUERY_LENGTH = 256

    Result = Data.define(:items, :next_cursor, :has_more)

    def self.call(user:, query:, feed_id: nil, since: nil, until_time: nil, sort: "relevance", limit: DEFAULT_LIMIT, cursor: nil)
      new(
        user: user,
        query: query,
        feed_id: feed_id,
        since: since,
        until_time: until_time,
        sort: sort,
        limit: limit,
        cursor: cursor
      ).call
    end

    def initialize(user:, query:, feed_id: nil, since: nil, until_time: nil, sort: "relevance", limit: DEFAULT_LIMIT, cursor: nil)
      @user = user
      @query = query.to_s.strip.truncate(MAX_QUERY_LENGTH, omission: "")
      @feed_id = feed_id.presence
      @since = parse_time(since)
      @until_time = parse_time(until_time)
      @sort = %w[relevance newest].include?(sort.to_s) ? sort.to_s : "relevance"
      @limit = (limit.nil? || limit.to_i <= 0) ? DEFAULT_LIMIT : limit.to_i.clamp(1, MAX_LIMIT)
      @offset = decode_cursor(cursor)
    end

    def call
      return Result.new(items: [], next_cursor: nil, has_more: false) if @query.blank?

      authorized_feed_ids = UserFeedSubscription.active.where(user_id: @user.id).select(:feed_id)

      scope = FeedItem.visible
        .includes(:feed)
        .where(feed_id: authorized_feed_ids)
      scope = scope.where(feed_id: @feed_id) if @feed_id
      scope = scope.where("COALESCE(feed_items.published_at, feed_items.first_seen_at) >= ?", @since) if @since
      scope = scope.where("COALESCE(feed_items.published_at, feed_items.first_seen_at) <= ?", @until_time) if @until_time

      tsq = ActiveRecord::Base.sanitize_sql_array([ "websearch_to_tsquery('english', ?)", @query ])
      scope = scope.where("feed_items.search_vector @@ #{tsq}")

      scope = if @sort == "newest"
        scope.order(Arel.sql("COALESCE(feed_items.published_at, feed_items.first_seen_at) DESC, feed_items.id DESC"))
      else
        scope.order(Arel.sql("ts_rank_cd(feed_items.search_vector, #{tsq}) DESC, COALESCE(feed_items.published_at, feed_items.first_seen_at) DESC"))
      end

      rows = scope.offset(@offset).limit(@limit + 1).to_a
      has_more = rows.size > @limit
      rows = rows.first(@limit)
      next_cursor = has_more ? encode_cursor(@offset + @limit) : nil

      Result.new(items: rows, next_cursor: next_cursor, has_more: has_more)
    end

    private

    def parse_time(val)
      return nil if val.blank?
      return val if val.is_a?(Time) || val.is_a?(ActiveSupport::TimeWithZone)

      Time.parse(val.to_s).utc
    rescue ArgumentError
      nil
    end

    def decode_cursor(raw)
      return 0 if raw.blank?

      decoded = Base64.urlsafe_decode64(raw.to_s)
      offset = Integer(decoded, 10)
      offset >= 0 ? offset : 0
    rescue ArgumentError
      0
    end

    def encode_cursor(offset)
      Base64.urlsafe_encode64(offset.to_s, padding: false)
    end
  end
end
