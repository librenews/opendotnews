class UserItem < ApplicationRecord
  belongs_to :user
  belongs_to :feed_item

  validates :feed_item_id, uniqueness: { scope: :user_id }

  scope :read_items, -> { where.not(read_at: nil) }
  scope :saved_items, -> { where.not(saved_at: nil) }
  scope :archived_items, -> { where.not(archived_at: nil) }

  def read?
    read_at.present?
  end

  def saved?
    saved_at.present?
  end

  def archived?
    archived_at.present?
  end

  def state_hash
    {
      read: read?,
      read_at: read_at&.iso8601,
      saved: saved?,
      saved_at: saved_at&.iso8601,
      archived: archived?,
      archived_at: archived_at&.iso8601
    }.compact
  end
end
