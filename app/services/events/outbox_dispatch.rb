module Events
  class OutboxDispatch
    DEFAULT_BATCH_SIZE = 100

    def self.call(batch_size: DEFAULT_BATCH_SIZE)
      new(batch_size: batch_size).call
    end

    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      @batch_size = batch_size
    end

    def call
      dispatched = 0

      OutboxEvent.transaction do
        events = OutboxEvent.undispatched.lock("FOR UPDATE SKIP LOCKED").limit(@batch_size).to_a

        events.each do |event|
          begin
            dispatch_event!(event)
            event.update_columns(
              dispatched_at: Time.current,
              attempts: event.attempts + 1,
              last_error: nil
            )
            dispatched += 1
          rescue StandardError => e
            event.update_columns(
              attempts: event.attempts + 1,
              last_error: "#{e.class}: #{e.message}".truncate(1000)
            )
            Rails.logger.error("Outbox dispatch failed for #{event.id} (#{event.event_type}): #{e.class}: #{e.message}")
          end
        end
      end

      dispatched
    end

    private

    def dispatch_event!(event)
      case event.event_type
      when "feed_item.created", "feed_item.updated"
        Events::MaterializeInboxJob.perform_async(event.id)
      when "document.created", "document.updated", "document.published",
           "document.unpublished", "document.deleted", "publication.feed_changed",
           "upstream_subscription.renewal_due"
        # Phase 2-4 fanout handlers plug in here.
        Rails.logger.info("Outbox event recorded for future phase handler: #{event.event_type} (#{event.id})")
      else
        Rails.logger.warn("Unhandled outbox event_type: #{event.event_type}")
      end
    end
  end
end
