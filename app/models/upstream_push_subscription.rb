require "digest"

class UpstreamPushSubscription < ApplicationRecord
  PROTOCOLS = %w[websub rsscloud].freeze
  STATUSES = %w[pending active unsubscribing unsubscribed expired error].freeze
  MODES = %w[subscribe unsubscribe].freeze

  belongs_to :feed
  has_many :staged_push_payloads, dependent: :destroy

  encrypts :secret
  encrypts :callback_token

  validates :protocol, inclusion: { in: PROTOCOLS }
  validates :status, inclusion: { in: STATUSES }
  validates :requested_mode, inclusion: { in: MODES }
  validates :hub_url, :topic_url, :callback_token_digest, :callback_token, presence: true

  scope :active, -> { where(status: "active") }
  scope :live, -> { where(status: %w[pending active unsubscribing]) }
  scope :due_for_renewal, ->(now = Time.current) {
    where(status: %w[active pending error])
      .where("next_renew_at IS NOT NULL AND next_renew_at <= ?", now)
  }

  def self.digest_token(raw_token)
    Digest::SHA256.hexdigest(raw_token.to_s)
  end

  def self.find_by_raw_token(raw_token)
    return nil if raw_token.blank?

    find_by(callback_token_digest: digest_token(raw_token))
  end

  def callback_url
    base = OpenNews.config.app_base_url
    case protocol
    when "websub"
      "#{base}/callbacks/websub/#{callback_token}"
    when "rsscloud"
      "#{base}/callbacks/rsscloud/#{callback_token}"
    end
  end

  def active?
    status == "active"
  end
end
