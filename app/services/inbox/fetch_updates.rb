module Inbox
  class FetchUpdates
    MAX_LIMIT = 100
    DEFAULT_LIMIT = 50
    MAX_INLINE_CONTENT_CHARS = 2_000

    Result = Data.define(:status, :events, :next_cursor, :has_more, :earliest_available_cursor, :error_code, :error) do
      def ok?
        status == :ok
      end

      def cursor_expired?
        status == :cursor_expired
      end
    end

    def self.call(user:, after_cursor: nil, limit: DEFAULT_LIMIT, feed_id: nil, include_content: false)
      new(
        user: user,
        after_cursor: after_cursor,
        limit: limit,
        feed_id: feed_id,
        include_content: include_content
      ).call
    end

    def initialize(user:, after_cursor: nil, limit: DEFAULT_LIMIT, feed_id: nil, include_content: false)
      @user = user
      @after_cursor = after_cursor.present? ? after_cursor.to_i : nil
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @limit = DEFAULT_LIMIT if limit.nil? || limit.to_i <= 0
      @feed_id = feed_id.presence
      @include_content = ActiveModel::Type::Boolean.new.cast(include_content)
    end

    def call
      if @after_cursor && @after_cursor > 0
        min_retained_id = UserInboxEvent.where(user_id: @user.id).minimum(:id)
        if min_retained_id && @after_cursor < min_retained_id && !UserInboxEvent.exists?(user_id: @user.id, id: @after_cursor)
          return Result.new(
            status: :cursor_expired,
            events: [],
            next_cursor: nil,
            has_more: false,
            earliest_available_cursor: min_retained_id,
            error_code: "cursor_expired",
            error: "Cursor #{@after_cursor} is older than retained inbox history; resync starting from after_cursor=0 or list_feed_items"
          )
        end
      end

      scope = UserInboxEvent.where(user_id: @user.id).ordered
      scope = scope.after_cursor(@after_cursor) if @after_cursor && @after_cursor > 0
      scope = scope.where(feed_id: @feed_id) if @feed_id
      scope = scope.includes(:feed_item) if @include_content

      rows = scope.limit(@limit + 1).to_a
      has_more = rows.size > @limit
      rows = rows.first(@limit)

      events = rows.map { |ev| serialize_event(ev) }
      next_cursor = rows.last ? rows.last.id : @after_cursor

      Result.new(
        status: :ok,
        events: events,
        next_cursor: next_cursor,
        has_more: has_more,
        earliest_available_cursor: nil,
        error_code: nil,
        error: nil
      )
    end

    private

    def serialize_event(ev)
      payload = {
        cursor: ev.id,
        event_type: ev.event_type,
        feed_id: ev.feed_id,
        feed_item_id: ev.feed_item_id,
        document_id: ev.document_id,
        occurred_at: ev.occurred_at.iso8601,
        metadata: ev.metadata
      }
      if @include_content && ev.feed_item
        payload[:content_text] = ev.feed_item.content_text.to_s.truncate(MAX_INLINE_CONTENT_CHARS)
      end
      payload
    end
  end
end
