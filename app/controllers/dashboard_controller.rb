class DashboardController < ApplicationController
  before_action :require_authentication

  def index
    @subscriptions = UserFeedSubscription.active
      .includes(:feed)
      .where(user_id: current_user.id)
      .order(subscribed_at: :desc)

    @query = params[:q].to_s.strip
    @selected_feed_id = params[:feed_id].presence

    if @query.present?
      search_res = Search::Items.call(user: current_user, query: @query, feed_id: @selected_feed_id, limit: 30)
      @items = search_res.items
    else
      list_res = Feeds::ListItems.call(user: current_user, feed_id: @selected_feed_id, limit: 30)
      @items = list_res.items
    end

    @recent_imports = OpmlImport.where(user_id: current_user.id).order(created_at: :desc).limit(5)
  end
end
