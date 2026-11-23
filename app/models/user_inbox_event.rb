class UserInboxEvent < ApplicationRecord
  belongs_to :user
  belongs_to :feed, optional: true
  belongs_to :feed_item, optional: true

  validates :event_type, :outbox_event_id, :occurred_at, presence: true
  validates :outbox_event_id, uniqueness: { scope: :user_id }

  scope :after_cursor, ->(cursor) { where("id > ?", cursor.to_i) }
  scope :ordered, -> { order(id: :asc) }
end
