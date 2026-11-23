class FeedAlias < ApplicationRecord
  REASONS = %w[redirect discovery input].freeze

  belongs_to :feed

  validates :url, presence: true, uniqueness: true
  validates :reason, inclusion: { in: REASONS }
end
