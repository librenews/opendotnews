module Delivery
  class RetryDueJob
    include Sidekiq::Job

    sidekiq_options queue: "scheduled", retry: 2

    def perform(batch_size = 100)
      to_enqueue = []

      DeliveryAttempt.transaction do
        attempts = DeliveryAttempt.due_for_retry
          .includes(:downstream_subscription)
          .lock("FOR UPDATE SKIP LOCKED")
          .limit(batch_size)
          .to_a

        attempts.each do |attempt|
          sub = attempt.downstream_subscription
          unless sub&.active?
            attempt.update!(status: "failed", next_attempt_at: nil, last_error: "Subscription no longer active")
            next
          end

          next_number = attempt.attempt_number + 1
          attempt.update!(status: "failed", next_attempt_at: nil)

          begin
            DeliveryAttempt.create!(
              downstream_subscription: sub,
              outbox_event_id: attempt.outbox_event_id,
              attempt_number: next_number,
              status: "pending"
            )
          rescue ActiveRecord::RecordNotUnique
            next
          end

          to_enqueue << [ sub.protocol, sub.id, attempt.outbox_event_id, next_number ]
        end
      end

      to_enqueue.each do |protocol, sub_id, event_id, next_number|
        case protocol
        when "websub"
          WebSub::DeliverContentJob.perform_async(sub_id, event_id, next_number)
        when "rsscloud"
          RssCloud::DeliverPingJob.perform_async(sub_id, event_id, next_number)
        end
      end

      to_enqueue.size
    end
  end
end
