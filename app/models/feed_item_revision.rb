class FeedItemRevision < ApplicationRecord
  belongs_to :feed_item

  validates :revision_number, presence: true, uniqueness: { scope: :feed_item_id }
  validates :content_hash, :recorded_at, presence: true
end
