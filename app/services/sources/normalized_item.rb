module Sources
  # Canonical source-agnostic normalized item produced by any source adapter
  # (RSS/Atom feeds today; website or browser-based adapters in the future).
  NormalizedItem = Data.define(
    :external_id,
    :external_url,
    :title,
    :author,
    :summary_text,
    :content_html_sanitized,
    :content_text,
    :published_at,
    :source_updated_at,
    :content_hash,
    :metadata
  ) do
    def initialize(
      external_id:,
      external_url: nil,
      title: nil,
      author: nil,
      summary_text: nil,
      content_html_sanitized: nil,
      content_text: nil,
      published_at: nil,
      source_updated_at: nil,
      content_hash:,
      metadata: {}
    )
      super
    end
  end
end
