class DownstreamSubscription < ApplicationRecord
  PROTOCOLS = %w[websub rsscloud].freeze
  TOPIC_FORMATS = %w[rss atom].freeze
  STATUSES = %w[pending active expired unsubscribed suspended].freeze

  belongs_to :publication
  has_many :delivery_attempts, dependent: :destroy

  encrypts :secret

  validates :protocol, inclusion: { in: PROTOCOLS }
  validates :topic_format, inclusion: { in: TOPIC_FORMATS }
  validates :status, inclusion: { in: STATUSES }
  validates :topic_url, :callback_url, :callback_host, presence: true

  scope :active, -> { where(status: "active") }
  scope :deliverable, ->(now = Time.current) {
    active.where("lease_expires_at IS NULL OR lease_expires_at > ?", now)
  }

  def active?
    status == "active" && (lease_expires_at.nil? || lease_expires_at > Time.current)
  end
end
