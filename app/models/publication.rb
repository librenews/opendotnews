class Publication < ApplicationRecord
  belongs_to :user
  has_many :documents, dependent: :destroy

  validates :slug, presence: true, uniqueness: { scope: :user_id }
  validates :title, presence: true
  validates :visibility, inclusion: { in: %w[public private] }
end
