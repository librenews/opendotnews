class FeedsController < ApplicationController
  before_action :require_authentication

  def show
    @feed = Feed.find_by(id: params[:id])
    return head(:not_found) unless @feed

    unless current_user.admin? || UserFeedSubscription.active.exists?(user_id: current_user.id, feed_id: @feed.id)
      return head(:forbidden)
    end

    @item_count = @feed.feed_items.visible.count
    @aliases = @feed.feed_aliases.order(created_at: :asc)
    @push_subscriptions = @feed.upstream_push_subscriptions.order(created_at: :desc).limit(10)
  end
end
