module Maintenance
  class ExpireLeasesJob
    include Sidekiq::Job

    sidekiq_options queue: "maintenance", retry: 2

    def perform
      now = Time.current
      expired_active = DownstreamSubscription.active
        .where("lease_expires_at IS NOT NULL AND lease_expires_at <= ?", now)
        .update_all(status: "expired", updated_at: now)

      expired_pending = DownstreamSubscription.where(status: "pending")
        .where("verification_expires_at IS NOT NULL AND verification_expires_at <= ?", now)
        .update_all(status: "expired", updated_at: now)

      expired_active + expired_pending
    end
  end
end
