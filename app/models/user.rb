class User < ApplicationRecord
  RESERVED_NAMESPACES = %w[
    admin api assets auth callbacks dashboard documents feed feeds health items
    login logout mcp oauth opendotnews opennews opml rails rsscloud settings
    sidekiq signup subscriptions system up websub well-known www root internal
    metrics status
  ].freeze

  NAMESPACE_FORMAT = /\A[a-z0-9][a-z0-9_-]{1,30}[a-z0-9]\z/

  has_secure_password

  has_many :sessions, dependent: :destroy
  has_many :publications, dependent: :destroy
  has_many :user_feed_subscriptions, dependent: :destroy
  has_many :active_subscriptions, -> { active }, class_name: "UserFeedSubscription"
  has_many :feeds, through: :active_subscriptions
  has_many :user_items, dependent: :destroy
  has_many :user_inbox_events, dependent: :destroy
  has_many :opml_imports, dependent: :destroy
  has_many :idempotency_keys, dependent: :destroy
  has_many :audit_logs, dependent: :nullify
  has_many :oauth_access_tokens, class_name: "Doorkeeper::AccessToken", foreign_key: :resource_owner_id, dependent: :destroy

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }
  normalizes :namespace, with: ->(n) { n.to_s.strip.downcase }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: { case_sensitive: false }
  validates :namespace, presence: true,
    length: { in: 3..32 },
    format: { with: NAMESPACE_FORMAT, message: "must be 3-32 lowercase ASCII letters, digits, _ or - (cannot start or end with _ or -)" },
    exclusion: { in: RESERVED_NAMESPACES, message: "is reserved" },
    uniqueness: { case_sensitive: false }
  validate :namespace_immutable, on: :update

  after_create :create_default_publication!

  def active?
    disabled_at.nil?
  end

  def operator?
    active? && (admin? || OpenNews.config.operator_emails.include?(email.to_s.downcase))
  end

  def disable!
    transaction do
      update!(disabled_at: Time.current)
      sessions.delete_all
      Doorkeeper::AccessToken.where(resource_owner_id: id, revoked_at: nil).update_all(revoked_at: Time.current)
      Doorkeeper::AccessGrant.where(resource_owner_id: id, revoked_at: nil).update_all(revoked_at: Time.current)
    end
  end

  def default_publication
    publications.find_by(slug: "default") || publications.first
  end

  private

  def namespace_immutable
    if will_save_change_to_namespace?
      errors.add(:namespace, "cannot be changed after creation")
    end
  end

  def create_default_publication!
    publications.create!(slug: "default", title: namespace, visibility: "public")
  end
end
