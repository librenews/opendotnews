module Subscriptions
  class Unsubscribe
    Result = Data.define(:status, :unsubscribed)

    def self.call(user:, feed_id:)
      new(user: user, feed_id: feed_id).call
    end

    def initialize(user:, feed_id:)
      @user = user
      @feed_id = feed_id
    end

    def call
      sub = UserFeedSubscription.active.find_by(user_id: @user.id, feed_id: @feed_id)
      return Result.new(status: :ok, unsubscribed: false) unless sub

      sub.update!(unsubscribed_at: Time.current)
      AuditLog.record!(
        action: "feed.unsubscribed",
        user: @user,
        resource_type: "Feed",
        resource_id: @feed_id,
        scope: "feeds:write"
      )
      Result.new(status: :ok, unsubscribed: true)
    end
  end
end
