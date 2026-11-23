module Push
  class RenewUpstreamJob
    include Sidekiq::Job

    sidekiq_options queue: "scheduled", retry: 2

    def perform(limit = 100)
      Push::Reconciler.renew_due!(limit: limit)
    end
  end
end
