require "base64"

module Feeds
  class ListItems
    MAX_LIMIT = 100
    DEFAULT_LIMIT = 25

    Result = Data.define(:items, :next_cursor, :has_more)

    def self.call(
      user:,
      feed_id: nil,
      since: nil,
      until_time: nil,
      cursor: nil,
      limit: DEFAULT_LIMIT,
      unread_only: false,
      saved_only: false,
      exclude_archived: false
    )
      new(
        user: user,
        feed_id: feed_id,
        since: since,
        until_time: until_time,
        cursor: cursor,
        limit: limit,
        unread_only: unread_only,
        saved_only: saved_only,
        exclude_archived: exclude_archived
      ).call
    end

    def initialize(
      user:,
      feed_id: nil,
      since: nil,
      until_time: nil,
      cursor: nil,
      limit: DEFAULT_LIMIT,
      unread_only: false,
      saved_only: false,
      exclude_archived: false
    )
      @user = user
      @feed_id = feed_id.presence
      @since = parse_time(since)
      @until_time = parse_time(until_time)
      @offset = decode_cursor(cursor)
      @limit = (limit.nil? || limit.to_i <= 0) ? DEFAULT_LIMIT : limit.to_i.clamp(1, MAX_LIMIT)
      @unread_only = ActiveModel::Type::Boolean.new.cast(unread_only)
      @saved_only = ActiveModel::Type::Boolean.new.cast(saved_only)
      @exclude_archived = ActiveModel::Type::Boolean.new.cast(exclude_archived)
    end

    def call
      authorized_feed_ids = UserFeedSubscription.active.where(user_id: @user.id).select(:feed_id)
      scope = FeedItem.visible.includes(:feed).where(feed_id: authorized_feed_ids)
      scope = scope.where(feed_id: @feed_id) if @feed_id
      scope = scope.where("COALESCE(feed_items.published_at, feed_items.first_seen_at) >= ?", @since) if @since
      scope = scope.where("COALESCE(feed_items.published_at, feed_items.first_seen_at) <= ?", @until_time) if @until_time

      if @unread_only || @saved_only || @exclude_archived
        join_sql = ActiveRecord::Base.sanitize_sql_array([
          "LEFT OUTER JOIN user_items ON user_items.feed_item_id = feed_items.id AND user_items.user_id = ?",
          @user.id
        ])
        scope = scope.joins(join_sql)
        scope = scope.where("user_items.read_at IS NULL") if @unread_only
        scope = scope.where("user_items.saved_at IS NOT NULL") if @saved_only
        scope = scope.where("user_items.archived_at IS NULL") if @exclude_archived
      end

      scope = scope.recent_first

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

      offset = Integer(Base64.urlsafe_decode64(raw.to_s), 10)
      offset >= 0 ? offset : 0
    rescue ArgumentError
      0
    end

    def encode_cursor(offset)
      Base64.urlsafe_encode64(offset.to_s, padding: false)
    end
  end
end
