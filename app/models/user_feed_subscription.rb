class UserFeedSubscription < ApplicationRecord
  belongs_to :user
  belongs_to :feed

  scope :active, -> { where(unsubscribed_at: nil) }

  validates :subscribed_at, presence: true
  validates :feed_id, uniqueness: { scope: :user_id, conditions: -> { where(unsubscribed_at: nil) } }

  def active?
    unsubscribed_at.nil?
  end
end
