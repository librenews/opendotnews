module Push
  class AcceptWebSubPayloadJob
    include Sidekiq::Job

    sidekiq_options queue: "critical_callbacks", retry: 5

    def perform(staged_payload_id)
      WebSub::Subscriber.process_staged_payload(staged_payload_id)
    end
  end
end
