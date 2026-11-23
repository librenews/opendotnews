class StagedPushPayload < ApplicationRecord
  STATUSES = %w[pending processed failed].freeze

  belongs_to :upstream_push_subscription
  belongs_to :feed

  validates :status, inclusion: { in: STATUSES }
  validates :body, :body_sha256, :received_at, presence: true

  scope :pending, -> { where(status: "pending").order(received_at: :asc) }
end
