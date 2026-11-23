module WebSub
  class DeliverContentJob
    include Sidekiq::Job

    # Retries are scheduled explicitly via Delivery::OutcomeHandler + Delivery::RetryDueJob.
    sidekiq_options queue: "fanout", retry: 0

    def perform(subscription_id, outbox_event_id, attempt_number = 1)
      sub = DownstreamSubscription.find_by(id: subscription_id)
      event = OutboxEvent.find_by(id: outbox_event_id)
      return unless sub && event

      WebSub::Hub.deliver!(subscription: sub, outbox_event: event, attempt_number: attempt_number.to_i)
    end
  end
end
