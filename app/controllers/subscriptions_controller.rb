class SubscriptionsController < ApplicationController
  before_action :require_authentication

  def create
    res = Subscriptions::Subscribe.call(
      user: current_user,
      url: params[:url],
      folder: params[:folder]
    )

    if res.ok?
      redirect_to dashboard_path, notice: "Subscribed to #{res.feed.title.presence || res.feed.canonical_url}."
    elsif res.selection_required?
      urls = res.candidates.map(&:url).join(", ")
      redirect_to dashboard_path, alert: "Multiple feeds found. Subscribe directly to one: #{urls}"
    else
      redirect_to dashboard_path, alert: "Could not subscribe: #{res.error}"
    end
  end

  def destroy
    Subscriptions::Unsubscribe.call(user: current_user, feed_id: params[:id])
    redirect_to dashboard_path, notice: "Unsubscribed."
  end
end
