class PublishingDeliveriesController < ApplicationController
  before_action :require_authentication

  def index
    @publication = current_user.default_publication
    @subscriptions = @publication.downstream_subscriptions.order(created_at: :desc).limit(100)
    @attempts = DeliveryAttempt
      .joins(:downstream_subscription)
      .where(downstream_subscriptions: { publication_id: @publication.id })
      .includes(:downstream_subscription, :outbox_event)
      .order(created_at: :desc)
      .limit(100)
  end
end
