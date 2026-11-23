class DocumentRevision < ApplicationRecord
  belongs_to :document
  belongs_to :created_by_user, class_name: "User"

  validates :revision_number, presence: true, uniqueness: { scope: :document_id }
  validates :markdown, :sha256, presence: true
end
