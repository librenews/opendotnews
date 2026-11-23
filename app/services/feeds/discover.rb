require "nokogiri"

module Feeds
  class Discover
    FEED_MIME_TYPES = %w[
      application/rss+xml
      application/atom+xml
      application/xml
      text/xml
      application/rdf+xml
    ].freeze

    Candidate = Data.define(:url, :title, :mime_type)

    Result = Data.define(:status, :canonical_url, :parsed_feed, :response, :candidates, :error) do
      def found?
        status == :found
      end

      def selection_required?
        status == :selection_required
      end
    end

    def self.call(url, fetcher: nil)
      new(url, fetcher: fetcher).call
    end

    def initialize(url, fetcher: nil)
      @url = url.to_s.strip
      @fetcher = fetcher || Security::SafeHttpFetch.new
    end

    def call
      resp = @fetcher.get(@url)
      unless resp.success?
        return Result.new(status: :error, canonical_url: nil, parsed_feed: nil, response: resp, candidates: [], error: "HTTP #{resp.status}")
      end

      # 1. Detect feed by actual XML content, never by URL extension.
      if (parsed = try_parse_feed(resp))
        canonical = select_canonical_url(resp.final_url, parsed.self_url)
        return Result.new(
          status: :found,
          canonical_url: canonical,
          parsed_feed: parsed,
          response: resp,
          candidates: [],
          error: nil
        )
      end

      # 2. Treat as HTML page and inspect <link rel="alternate"> feed advertisements.
      candidates = discover_html_links(resp.body, resp.final_url)
      if candidates.empty?
        return Result.new(status: :not_found, canonical_url: nil, parsed_feed: nil, response: resp, candidates: [], error: "No RSS or Atom feed found at URL")
      end

      if candidates.size > 1
        return Result.new(
          status: :selection_required,
          canonical_url: nil,
          parsed_feed: nil,
          response: resp,
          candidates: candidates,
          error: nil
        )
      end

      # Single unambiguous candidate: fetch and verify it is a valid feed.
      feed_resp = @fetcher.get(candidates.first.url)
      unless feed_resp.success?
        return Result.new(status: :error, canonical_url: nil, parsed_feed: nil, response: feed_resp, candidates: candidates, error: "Discovered feed returned HTTP #{feed_resp.status}")
      end

      parsed = try_parse_feed(feed_resp)
      unless parsed
        return Result.new(status: :not_found, canonical_url: nil, parsed_feed: nil, response: feed_resp, candidates: candidates, error: "Discovered link is not a valid RSS/Atom feed")
      end

      canonical = select_canonical_url(feed_resp.final_url, parsed.self_url)
      Result.new(
        status: :found,
        canonical_url: canonical,
        parsed_feed: parsed,
        response: feed_resp,
        candidates: candidates,
        error: nil
      )
    rescue Security::SafeHttpFetch::Error => e
      Result.new(status: :error, canonical_url: nil, parsed_feed: nil, response: nil, candidates: [], error: e.message)
    end

    private

    def try_parse_feed(resp)
      Feeds::Parse.call(resp.body, headers: resp.headers, base_url: resp.final_url)
    rescue Feeds::Parse::ParseError
      nil
    end

    def discover_html_links(html, base_url)
      doc = Nokogiri::HTML(html.to_s, nil, nil, Nokogiri::XML::ParseOptions::NONET)
      seen = {}
      out = []

      doc.xpath("//link").each do |link|
        rels = link["rel"].to_s.downcase.split(/\s+/)
        next unless rels.include?("alternate")

        mime = link["type"].to_s.downcase.split(";").first&.strip
        next unless FEED_MIME_TYPES.include?(mime)

        resolved = UrlNormalizer.resolve(base_url, link["href"])
        next if resolved.blank? || seen[resolved]

        seen[resolved] = true
        out << Candidate.new(
          url: resolved,
          title: link["title"].to_s.strip.presence,
          mime_type: mime
        )
      end

      out
    end

    # Only adopt a feed's rel="self" link when it shares the same host (prevents cross-domain hijacking).
    def select_canonical_url(final_url, self_url)
      norm_final = UrlNormalizer.normalize(final_url) || final_url
      return norm_final if self_url.blank?

      norm_self = UrlNormalizer.normalize(self_url)
      return norm_final if norm_self.blank?

      if URI.parse(norm_self).host == URI.parse(norm_final).host
        norm_self
      else
        norm_final
      end
    rescue URI::InvalidURIError
      norm_final
    end
  end
end
