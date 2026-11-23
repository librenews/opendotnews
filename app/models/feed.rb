class Feed < ApplicationRecord
  STATUSES = %w[active paused error].freeze
  SOURCE_TYPES = %w[feed web browser].freeze

  has_many :feed_aliases, dependent: :destroy
  has_many :feed_items, dependent: :destroy
  has_many :user_feed_subscriptions, dependent: :destroy
  has_many :active_user_subscriptions, -> { active }, class_name: "UserFeedSubscription"
  has_many :subscribers, through: :active_user_subscriptions, source: :user
  has_many :upstream_push_subscriptions, dependent: :destroy
  has_many :staged_push_payloads, dependent: :destroy

  validates :canonical_url, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }

  scope :due_for_fetch, ->(now = Time.current) {
    where(status: %w[active error])
      .where("next_fetch_at IS NULL OR next_fetch_at <= ?", now)
      .where("fetching_started_at IS NULL OR fetching_started_at < ?", now - 5.minutes)
  }

  def active_subscriber_count
    active_user_subscriptions.count
  end
end
