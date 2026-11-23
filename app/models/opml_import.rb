class OpmlImport < ApplicationRecord
  STATUSES = %w[pending processing completed failed].freeze

  belongs_to :user

  validates :status, inclusion: { in: STATUSES }
end
