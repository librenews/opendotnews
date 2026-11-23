module Events
  class MaterializeInboxJob
    include Sidekiq::Job

    sidekiq_options queue: "fanout", retry: 8

    def perform(outbox_event_id)
      Events::InboxFanout.call(outbox_event_id)
    end
  end
end
