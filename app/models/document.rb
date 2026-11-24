class Document < ApplicationRecord
  belongs_to :publication
  has_many :document_revisions, dependent: :destroy

  validates :path, presence: true, uniqueness: { scope: :publication_id }
  validates :title, :rss_guid, :content_sha256, presence: true
  validates :visibility, inclusion: { in: %w[draft public] }

  scope :live, -> { where(deleted_at: nil) }
  scope :publicly_visible, -> { live.where(visibility: "public", moderated_at: nil) }
  scope :drafts, -> { live.where(visibility: "draft") }

  def public?
    deleted_at.nil? && moderated_at.nil? && visibility == "public"
  end

  def moderated?
    moderated_at.present?
  end

  def draft?
    deleted_at.nil? && visibility == "draft"
  end

  def deleted?
    deleted_at.present?
  end

  def current_revision
    document_revisions.find_by(revision_number: current_revision_number)
  end

  def revision(num)
    document_revisions.find_by(revision_number: num.to_i)
  end

  def namespace
    publication.user.namespace
  end

  def canonical_url
    "#{OpenNews.config.app_base_url}/#{namespace}/#{path}"
  end

  def markdown_url
    "#{canonical_url}.md"
  end
end
