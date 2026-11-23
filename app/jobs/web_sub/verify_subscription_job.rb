module WebSub
  class VerifySubscriptionJob
    include Sidekiq::Job

    sidekiq_options queue: "critical_callbacks", retry: 3

    def perform(subscription_id, mode, challenge, lease_seconds = nil)
      sub = DownstreamSubscription.find_by(id: subscription_id)
      return unless sub

      WebSub::Hub.verify_subscription!(sub, mode: mode, challenge: challenge, lease_seconds: lease_seconds)
    end
  end
end
