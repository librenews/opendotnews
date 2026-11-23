class Document < ApplicationRecord
  belongs_to :publication
  has_many :document_revisions, dependent: :destroy

  validates :path, presence: true, uniqueness: { scope: :publication_id }
  validates :title, :rss_guid, :content_sha256, presence: true
  validates :visibility, inclusion: { in: %w[draft public] }
end
