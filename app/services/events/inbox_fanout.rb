module Events
  class InboxFanout
    def self.call(outbox_event_id)
      new(outbox_event_id).call
    end

    def initialize(outbox_event_id)
      @outbox_event_id = outbox_event_id
    end

    def call
      event = OutboxEvent.find_by(id: @outbox_event_id)
      return 0 unless event

      case event.event_type
      when "feed_item.created", "feed_item.updated"
        materialize_feed_item_event(event)
      else
        0
      end
    end

    private

    def materialize_feed_item_event(event)
      item = FeedItem.includes(:feed).find_by(id: event.aggregate_id)
      return 0 unless item

      occurred_at = event.created_at || Time.current
      subscriber_ids = UserFeedSubscription
        .active
        .where(feed_id: item.feed_id)
        .where("subscribed_at <= ?", occurred_at)
        .pluck(:user_id)

      return 0 if subscriber_ids.empty?

      now = Time.current
      excerpt = (item.summary_text.presence || item.content_text.presence || "").truncate(400)
      metadata = {
        "title" => item.title,
        "external_url" => item.external_url,
        "author" => item.author,
        "feed_title" => item.feed&.title,
        "feed_url" => item.feed&.canonical_url,
        "published_at" => item.published_at&.iso8601,
        "revision_number" => event.aggregate_version,
        "excerpt" => excerpt
      }.compact

      rows = subscriber_ids.map do |uid|
        {
          user_id: uid,
          event_type: event.event_type,
          feed_id: item.feed_id,
          feed_item_id: item.id,
          outbox_event_id: event.id,
          occurred_at: occurred_at,
          metadata: metadata,
          created_at: now
        }
      end

      # Idempotent upsert prevents duplicate inbox events even when Sidekiq retries.
      UserInboxEvent.insert_all(rows, unique_by: %i[user_id outbox_event_id])
      rows.size
    end
  end
end
