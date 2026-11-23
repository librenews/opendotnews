require "digest"
require "loofah"

module Feeds
  class Normalize
    MAX_TEXT_LENGTH = 100_000
    MAX_SUMMARY_LENGTH = 4_000
    DANGEROUS_SCHEMES = /\A\s*(javascript|vbscript|data):/i

    # Keep backwards-compatible constant alias to canonical Sources::NormalizedItem.
    NormalizedItem = Sources::NormalizedItem

    def self.call(parsed_feed, feed_url:)
      new(parsed_feed, feed_url: feed_url).call
    end

    def initialize(parsed_feed, feed_url:)
      @parsed_feed = parsed_feed
      @feed_url = feed_url
      @base_url = parsed_feed.site_url.presence || feed_url
    end

    def call
      seen_ids = {}
      normalized = []

      @parsed_feed.items.each do |raw|
        item = normalize_item(raw)
        next if item.nil? || seen_ids[item.external_id]

        seen_ids[item.external_id] = true
        normalized << item
      end

      normalized
    end

    private

    def normalize_item(raw)
      external_url = UrlNormalizer.resolve(@base_url, raw.raw_url)
      title = clean_plain_text(raw.title)&.truncate(500)
      author = clean_plain_text(raw.author)&.truncate(255)

      sanitized_html = sanitize_html(raw.content_html)
      content_text = extract_plain_text(sanitized_html.presence || raw.content_html).truncate(MAX_TEXT_LENGTH)
      summary_text = if raw.summary.present?
        extract_plain_text(raw.summary).truncate(MAX_SUMMARY_LENGTH)
      else
        content_text.truncate(500)
      end

      # Skip completely empty/malformed items that carry neither identity nor content
      return nil if raw.raw_id.blank? && external_url.blank? && title.blank? && content_text.blank?

      external_id = resolve_external_id(raw.raw_id, external_url, title, raw.published_at, content_text)
      content_hash = compute_content_hash(title, external_url, author, summary_text, content_text)

      NormalizedItem.new(
        external_id: external_id,
        external_url: external_url,
        title: title,
        author: author,
        summary_text: summary_text.presence,
        content_html_sanitized: sanitized_html.presence,
        content_text: content_text.presence,
        published_at: raw.published_at,
        source_updated_at: raw.updated_at,
        content_hash: content_hash
      )
    end

    # Priority per spec Section 5.3: Atom id / RSS guid -> normalized permalink -> deterministic fallback.
    def resolve_external_id(raw_id, external_url, title, published_at, content_text)
      if raw_id.present?
        return raw_id.strip.truncate(500, omission: "")
      end
      if external_url.present?
        return external_url.truncate(500, omission: "")
      end
      fingerprint = Digest::SHA256.hexdigest([ title, published_at&.iso8601, content_text.to_s[0, 256] ].join("\0"))
      "fallback:#{fingerprint}"
    end

    def compute_content_hash(title, external_url, author, summary_text, content_text)
      Digest::SHA256.hexdigest([ title.to_s, external_url.to_s, author.to_s, summary_text.to_s, content_text.to_s ].join("\0"))
    end

    def sanitize_html(raw_html)
      return "" if raw_html.blank?

      frag = Loofah.fragment(raw_html.to_s)
      frag.scrub!(:prune)
      frag.scrub!(safe_link_scrubber)
      frag.to_html.strip
    end

    def safe_link_scrubber
      @safe_link_scrubber ||= Loofah::Scrubber.new do |node|
        next unless node.element?

        %w[href src].each do |attr|
          val = node[attr]
          if val.present? && val.match?(DANGEROUS_SCHEMES)
            node.remove_attribute(attr)
          end
        end
        node.attributes.keys.each do |name|
          node.remove_attribute(name) if name.downcase.start_with?("on")
        end
      end
    end

    def extract_plain_text(html_or_text)
      return "" if html_or_text.blank?

      Loofah.fragment(html_or_text.to_s).text(encode_special_chars: false).gsub(/\s+/, " ").strip
    end

    def clean_plain_text(str)
      return nil if str.blank?

      extract_plain_text(str).presence
    end
  end
end
