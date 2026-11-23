class OutboxEvent < ApplicationRecord
  EVENT_TYPES = %w[
    feed_item.created
    feed_item.updated
    document.created
    document.updated
    document.published
    document.unpublished
    document.deleted
    publication.feed_changed
    upstream_subscription.renewal_due
  ].freeze

  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :aggregate_type, :aggregate_id, :aggregate_version, presence: true

  scope :undispatched, -> { where(dispatched_at: nil).order(created_at: :asc) }

  # Trigger fast asynchronous dispatch after the surrounding DB transaction commits.
  # If Redis is down or the process crashes before enqueue, the recurring sweeper recovers it.
  after_commit :enqueue_dispatcher, on: :create

  private

  def enqueue_dispatcher
    Events::DispatchOutboxJob.perform_async
  rescue StandardError => e
    Rails.logger.warn("Outbox immediate enqueue skipped (sweeper will recover): #{e.class}: #{e.message}")
  end
end
