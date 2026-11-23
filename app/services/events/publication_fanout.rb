module Events
  class PublicationFanout
    def self.call(outbox_event_id)
      new(outbox_event_id).call
    end

    def initialize(outbox_event_id)
      @outbox_event_id = outbox_event_id
    end

    def call
      event = OutboxEvent.find_by(id: @outbox_event_id)
      return 0 unless event && event.event_type == "publication.feed_changed"

      publication_id = event.payload["publication_id"]
      return 0 if publication_id.blank?

      enqueued = 0

      DownstreamSubscription.deliverable.where(publication_id: publication_id).find_each do |sub|
        next if DeliveryAttempt.exists?(downstream_subscription_id: sub.id, outbox_event_id: event.id, attempt_number: 1)

        begin
          DeliveryAttempt.create!(
            downstream_subscription: sub,
            outbox_event: event,
            attempt_number: 1,
            status: "pending"
          )
        rescue ActiveRecord::RecordNotUnique
          next
        end

        case sub.protocol
        when "websub"
          WebSub::DeliverContentJob.perform_async(sub.id, event.id, 1)
          enqueued += 1
        when "rsscloud"
          RssCloud::DeliverPingJob.perform_async(sub.id, event.id, 1)
          enqueued += 1
        end
      end

      enqueued
    end
  end
end
