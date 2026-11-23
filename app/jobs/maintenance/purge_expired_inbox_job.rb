module Maintenance
  class PurgeExpiredInboxJob
    include Sidekiq::Job

    sidekiq_options queue: "maintenance", retry: 3

    def perform(retention_days = OpenNews.config.inbox_retention_days)
      cutoff = retention_days.to_i.days.ago
      UserInboxEvent.where("created_at < ?", cutoff).in_batches(of: 1000).delete_all
    end
  end
end
