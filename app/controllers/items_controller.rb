class ItemsController < ApplicationController
  before_action :require_authentication

  def show
    authorized_feed_ids = UserFeedSubscription.active.where(user_id: current_user.id).select(:feed_id)
    @item = FeedItem.visible.includes(:feed).where(feed_id: authorized_feed_ids).find_by(id: params[:id])
    head :not_found unless @item
  end
end
