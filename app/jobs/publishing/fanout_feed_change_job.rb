module Publishing
  class FanoutFeedChangeJob
    include Sidekiq::Job

    sidekiq_options queue: "fanout", retry: 5

    def perform(outbox_event_id)
      Events::PublicationFanout.call(outbox_event_id)
    end
  end
end
