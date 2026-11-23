module Push
  class RegisterUpstreamJob
    include Sidekiq::Job

    sidekiq_options queue: "scheduled", retry: 3

    def perform(feed_id)
      feed = Feed.find_by(id: feed_id)
      return unless feed

      Push::Reconciler.reconcile_feed(feed)
    end
  end
end
