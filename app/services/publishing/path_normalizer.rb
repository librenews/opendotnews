module Publishing
  module PathNormalizer
    class InvalidPathError < StandardError; end

    MAX_LENGTH = 180
    MAX_DEPTH = 6
    SEGMENT_REGEX = /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/
    RESERVED_PATHS = %w[feed.xml feed.atom feed rss atom index].freeze

    module_function

    def normalize!(raw_path)
      raw = raw_path.to_s
      raise InvalidPathError, "path is required" if raw.strip.empty?
      raise InvalidPathError, "path contains control characters or whitespace" if raw.match?(/[\x00-\x20\x7f]/)
      raise InvalidPathError, "path contains forbidden characters" if raw.include?("\\") || raw.include?("?") || raw.include?("#")
      raise InvalidPathError, "path contains encoded path separators" if raw.match?(/%2f|%5c/i)

      trimmed = raw.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      raise InvalidPathError, "path cannot be empty" if trimmed.empty?
      raise InvalidPathError, "path contains empty segments" if trimmed.include?("//")
      raise InvalidPathError, "path exceeds #{MAX_LENGTH} bytes" if trimmed.bytesize > MAX_LENGTH

      segments = trimmed.split("/")
      raise InvalidPathError, "path exceeds max depth of #{MAX_DEPTH}" if segments.size > MAX_DEPTH

      segments.each do |seg|
        if seg == "." || seg == ".."
          raise InvalidPathError, "relative path segments are forbidden"
        end
        unless seg.match?(SEGMENT_REGEX)
          raise InvalidPathError, "invalid path segment #{seg.inspect}"
        end
      end

      normalized = segments.join("/")
      if RESERVED_PATHS.include?(normalized.downcase) || RESERVED_PATHS.include?(segments.first.downcase)
        raise InvalidPathError, "path #{normalized.inspect} is reserved"
      end
      if normalized.downcase.end_with?(".md")
        raise InvalidPathError, "canonical document path must not end with .md (use .md only as the public Markdown URL alias)"
      end

      normalized
    end
  end
end
