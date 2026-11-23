class ItemsController < ApplicationController
  before_action :require_authentication

  def show
    authorized_feed_ids = UserFeedSubscription.active.where(user_id: current_user.id).select(:feed_id)
    @item = FeedItem.visible.includes(:feed).where(feed_id: authorized_feed_ids).find_by(id: params[:id])
    return head(:not_found) unless @item

    @user_item = UserItem.find_by(user_id: current_user.id, feed_item_id: @item.id)
  end

  def update_state
    bool = ActiveModel::Type::Boolean.new
    UserItems::UpdateState.call(
      user: current_user,
      feed_item_id: params[:id],
      read: params.key?(:read) ? bool.cast(params[:read]) : nil,
      saved: params.key?(:saved) ? bool.cast(params[:saved]) : nil,
      archived: params.key?(:archived) ? bool.cast(params[:archived]) : nil
    )
    redirect_to feed_item_path(params[:id]), notice: "Item state updated."
  rescue UserItems::UpdateState::NotFoundError
    head :not_found
  rescue UserItems::UpdateState::ForbiddenError
    head :forbidden
  end
end
