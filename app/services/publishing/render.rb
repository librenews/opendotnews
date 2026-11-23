require "commonmarker"
require "loofah"
require "yaml"
require "date"
require "time"

module Publishing
  class Render
    ALLOWED_FRONTMATTER_KEYS = %w[title description date tags].freeze
    DANGEROUS_SCHEMES = /\A\s*(javascript|vbscript|data):/i
    FRONTMATTER_REGEX = /\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)/m

    ParsedMarkdown = Data.define(:frontmatter, :body)

    def self.extract_frontmatter(markdown)
      text = markdown.to_s
      match = text.match(FRONTMATTER_REGEX)
      return ParsedMarkdown.new(frontmatter: {}, body: text) unless match

      raw_yaml = match[1]
      body = text[match[0].length..] || ""
      loaded = YAML.safe_load(raw_yaml, permitted_classes: [ Date, Time ], aliases: false)
      unless loaded.is_a?(Hash)
        return ParsedMarkdown.new(frontmatter: {}, body: body)
      end

      allowed = {}
      loaded.each do |k, v|
        key = k.to_s.downcase.strip
        next unless ALLOWED_FRONTMATTER_KEYS.include?(key)

        allowed[key] = case key
        when "tags"
          Array(v).map(&:to_s).map(&:strip).reject(&:blank?).first(20)
        else
          v.to_s.strip.truncate(500)
        end
      end

      ParsedMarkdown.new(frontmatter: allowed, body: body)
    rescue Psych::Exception
      # Treat invalid YAML frontmatter as literal text rather than crashing or deserializing unsafe objects.
      ParsedMarkdown.new(frontmatter: {}, body: text)
    end

    def self.derive_title(explicit_title:, frontmatter:, body:, path:)
      return explicit_title.to_s.strip.truncate(255) if explicit_title.present?
      return frontmatter["title"].to_s.strip.truncate(255) if frontmatter["title"].present?

      if (m = body.to_s.match(/^\s*#\s+(.+)$/))
        return m[1].strip.truncate(255)
      end

      File.basename(path.to_s).tr("_-", " ").capitalize.truncate(255)
    end

    def self.to_html(markdown)
      parsed = extract_frontmatter(markdown)
      # Commonmarker renders with unsafe: false (raw HTML stripped/escaped by default).
      raw_html = Commonmarker.to_html(
        parsed.body,
        options: {
          parse: { smart: false },
          render: { unsafe: false, hardbreaks: false },
          extension: {
            table: true,
            strikethrough: true,
            autolink: true,
            tasklist: true
          }
        }
      )

      # Defense-in-depth HTML sanitization via Loofah.
      frag = Loofah.fragment(raw_html)
      frag.scrub!(:prune)
      frag.scrub!(safe_link_scrubber)
      frag.to_html.strip
    end

    def self.excerpt(markdown, max_chars: 300)
      html = to_html(markdown)
      Loofah.fragment(html).text(encode_special_chars: false).gsub(/\s+/, " ").strip.truncate(max_chars)
    end

    def self.safe_link_scrubber
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
    private_class_method :safe_link_scrubber
  end
end
