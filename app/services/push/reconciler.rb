module Push
  class Reconciler
    def self.reconcile_feed(feed, fetcher: nil)
      new(fetcher: fetcher).reconcile_feed(feed)
    end

    def self.renew_due!(limit: 100, fetcher: nil, now: Time.current)
      new(fetcher: fetcher).renew_due!(limit: limit, now: now)
    end

    def self.recover_staged_payloads!(older_than: 1.minute, limit: 100)
      requeued = 0
      StagedPushPayload.pending.where("received_at <= ?", older_than.ago).limit(limit).find_each do |staged|
        Push::AcceptWebSubPayloadJob.perform_async(staged.id)
        requeued += 1
      end
      requeued
    end

    def initialize(fetcher: nil)
      @fetcher = fetcher
    end

    # Ensures at most one shared upstream push registration per canonical feed.
    # Prefers WebSub when advertised; falls back to rssCloud. Retires unused registrations.
    def reconcile_feed(feed)
      if feed.active_subscriber_count == 0
        retire_unused_subscriptions!(feed)
        return :retired
      end

      if feed.discovered_websub_hub.present?
        reconcile_websub!(feed)
        return :websub
      end

      if feed.discovered_rsscloud_endpoint.present?
        reconcile_rsscloud!(feed)
        return :rsscloud
      end

      :polling_only
    end

    def renew_due!(limit: 100, now: Time.current)
      processed = 0

      # 1. Mark expired leases so they can be re-registered cleanly if subscribers remain.
      UpstreamPushSubscription.active.where("lease_expires_at IS NOT NULL AND lease_expires_at <= ?", now).find_each do |sub|
        sub.update!(status: "expired", next_renew_at: nil)
        if sub.feed.active_subscriber_count > 0
          reconcile_feed(sub.feed)
        end
        processed += 1
      end

      # 2. Renew subscriptions approaching lease expiry (or retrying after hub transient error).
      UpstreamPushSubscription.includes(:feed).due_for_renewal(now).limit(limit).find_each do |sub|
        if sub.feed.active_subscriber_count == 0
          retire_subscription!(sub)
        elsif sub.protocol == "websub"
          WebSub::Subscriber.renew(sub, fetcher: @fetcher)
        elsif sub.protocol == "rsscloud"
          RssCloud::Consumer.renew(sub, fetcher: @fetcher)
        end
        processed += 1
      end

      # 3. Recover any staged WebSub payloads orphaned by a worker crash or Redis restart.
      self.class.recover_staged_payloads!

      processed
    end

    private

    def reconcile_websub!(feed)
      hub = Feeds::UrlNormalizer.normalize(feed.discovered_websub_hub)
      topic = Feeds::UrlNormalizer.normalize(feed.discovered_websub_topic.presence || feed.canonical_url)

      # Unsubscribe stale hubs if feed migrated to a different WebSub hub/topic.
      feed.upstream_push_subscriptions.live.where(protocol: "websub").find_each do |existing|
        next if existing.hub_url == hub && existing.topic_url == topic

        WebSub::Subscriber.unsubscribe(existing, fetcher: @fetcher)
      end

      return if feed.upstream_push_subscriptions.live.exists?(protocol: "websub", hub_url: hub, topic_url: topic)

      WebSub::Subscriber.subscribe(feed, fetcher: @fetcher)
    end

    def reconcile_rsscloud!(feed)
      endpoint = Feeds::UrlNormalizer.normalize(feed.discovered_rsscloud_endpoint)
      topic = Feeds::UrlNormalizer.normalize(feed.canonical_url)
      return if feed.upstream_push_subscriptions.live.exists?(protocol: "rsscloud", hub_url: endpoint, topic_url: topic)

      RssCloud::Consumer.register(feed, fetcher: @fetcher)
    end

    def retire_unused_subscriptions!(feed)
      feed.upstream_push_subscriptions.live.find_each { |sub| retire_subscription!(sub) }
    end

    def retire_subscription!(sub)
      if sub.protocol == "websub"
        WebSub::Subscriber.unsubscribe(sub, fetcher: @fetcher)
      else
        sub.update!(status: "unsubscribed", next_renew_at: nil)
      end
    end
  end
end
