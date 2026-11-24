require "sidekiq/api"

module Operations
  # Section 14.2 operator metrics snapshot (PostgreSQL + Sidekiq + push delivery health).
  module MetricsSnapshot
    module_function

    def call
      now = Time.current
      since_24h = 24.hours.ago

      attempts_24h = DeliveryAttempt.where("created_at >= ?", since_24h)
      attempts_total = attempts_24h.count
      attempts_delivered = attempts_24h.where(status: "delivered").count
      attempts_failed = attempts_24h.where(status: "failed").count
      success_rate = attempts_total.positive? ? ((attempts_delivered.to_f / attempts_total) * 100).round(2) : 100.0

      oldest_undispatched = OutboxEvent.undispatched.minimum(:created_at)

      {
        generated_at: now.utc.iso8601,
        users: {
          total: User.count,
          active: User.where(disabled_at: nil).count,
          disabled: User.where.not(disabled_at: nil).count
        },
        oauth: {
          applications: Doorkeeper::Application.count,
          active_tokens: Doorkeeper::AccessToken.where(revoked_at: nil).count
        },
        feeds: {
          total: Feed.count,
          active: Feed.where(status: "active").count,
          failing: Feed.where("fetch_failure_count > 0").count,
          active_subscriptions: UserFeedSubscription.active.count,
          items_total: FeedItem.count,
          items_24h: FeedItem.where("created_at >= ?", since_24h).count
        },
        publishing: {
          publications_public: Publication.where(visibility: "public").count,
          documents_live: Document.live.count,
          documents_public: Document.publicly_visible.count,
          documents_draft: Document.drafts.count,
          documents_moderated: Document.where.not(moderated_at: nil).count,
          total_storage_bytes: DocumentRevision.sum("octet_length(markdown)").to_i
        },
        upstream_push: {
          websub_active: UpstreamPushSubscription.where(protocol: "websub", status: "active").count,
          rsscloud_active: UpstreamPushSubscription.where(protocol: "rsscloud", status: "active").count,
          failing: UpstreamPushSubscription.where("failure_count > 0").count,
          staged_pending: StagedPushPayload.where(processed_at: nil).count
        },
        downstream_push: {
          websub_active: DownstreamSubscription.deliverable.where(protocol: "websub").count,
          rsscloud_active: DownstreamSubscription.deliverable.where(protocol: "rsscloud").count,
          expired: DownstreamSubscription.where(status: "expired").count,
          suspended: DownstreamSubscription.where(status: "suspended").count,
          attempts_24h_total: attempts_total,
          attempts_24h_delivered: attempts_delivered,
          attempts_24h_failed: attempts_failed,
          delivery_success_rate_24h: success_rate,
          retries_due: DeliveryAttempt.due_for_retry.count
        },
        outbox: {
          undispatched_count: OutboxEvent.undispatched.count,
          oldest_undispatched_age_seconds: oldest_undispatched ? (now - oldest_undispatched).round(1) : 0.0
        },
        sidekiq: sidekiq_metrics,
        database: {
          size_bytes: database_size_bytes
        }
      }
    end

    def sidekiq_metrics
      queues = {}
      Sidekiq::Queue.all.each do |q|
        queues[q.name] = { size: q.size, latency_seconds: q.latency.round(2) }
      end
      stats = Sidekiq::Stats.new
      {
        status: "ok",
        processed: stats.processed,
        failed: stats.failed,
        enqueued: stats.enqueued,
        retry_size: stats.retry_size,
        dead_size: stats.dead_size,
        queues: queues
      }
    rescue StandardError => e
      { status: "unavailable", error: e.class.name }
    end

    def database_size_bytes
      ActiveRecord::Base.connection.select_value("SELECT pg_database_size(current_database())").to_i
    rescue StandardError
      0
    end
  end
end
