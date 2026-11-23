class FeedItem < ApplicationRecord
  belongs_to :feed
  has_many :feed_item_revisions, dependent: :destroy

  validates :external_id, presence: true, uniqueness: { scope: :feed_id }
  validates :content_hash, presence: true
  validates :first_seen_at, :last_seen_at, presence: true

  scope :visible, -> { where(is_deleted: false) }
  scope :recent_first, -> { order(Arel.sql("COALESCE(published_at, first_seen_at) DESC, id DESC")) }
end
