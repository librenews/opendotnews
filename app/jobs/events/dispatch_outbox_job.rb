module Events
  class DispatchOutboxJob
    include Sidekiq::Job

    sidekiq_options queue: "scheduled", retry: 5

    def perform(batch_size = Events::OutboxDispatch::DEFAULT_BATCH_SIZE)
      Events::OutboxDispatch.call(batch_size: batch_size)
    end
  end
end
