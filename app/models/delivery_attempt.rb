class DeliveryAttempt < ApplicationRecord
  STATUSES = %w[pending delivered retry_scheduled failed].freeze

  belongs_to :downstream_subscription
  belongs_to :outbox_event

  validates :status, inclusion: { in: STATUSES }
  validates :attempt_number, numericality: { only_integer: true, greater_than: 0 }

  scope :due_for_retry, ->(now = Time.current) {
    where(status: "retry_scheduled")
      .where("next_attempt_at IS NOT NULL AND next_attempt_at <= ?", now)
      .order(next_attempt_at: :asc)
  }
end
