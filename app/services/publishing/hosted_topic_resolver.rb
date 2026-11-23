require "uri"

module Publishing
  # Resolves a topic URL ONLY if it is a public hosted RSS or Atom feed owned by this Open.News instance.
  # Rejects arbitrary external URLs, private publications, and disabled accounts.
  module HostedTopicResolver
    ResolvedTopic = Data.define(:publication, :format, :canonical_topic_url)

    module_function

    def resolve(raw_topic_url, allowed_formats: %w[rss atom])
      norm = Feeds::UrlNormalizer.normalize(raw_topic_url)
      return nil if norm.blank?

      base = URI.parse(OpenNews.config.app_base_url)
      uri = URI.parse(norm)

      base_port = base.port || (base.scheme == "https" ? 443 : 80)
      uri_port = uri.port || (uri.scheme == "https" ? 443 : 80)
      return nil unless uri.host.downcase == base.host.downcase && uri_port == base_port

      match = uri.path.match(%r{\A/([a-zA-Z0-9][a-zA-Z0-9_-]{1,30}[a-zA-Z0-9])/(feed\.xml|feed\.atom)\z})
      return nil unless match

      ns = match[1].downcase
      format = (match[2] == "feed.xml") ? "rss" : "atom"
      return nil unless allowed_formats.include?(format)
      return nil if User::RESERVED_NAMESPACES.include?(ns)

      owner = User.find_by("LOWER(namespace) = ?", ns)
      return nil unless owner&.active?

      pub = owner.default_publication
      return nil unless pub&.visibility == "public"

      canonical = "#{OpenNews.config.app_base_url}/#{owner.namespace}/#{match[2]}"
      ResolvedTopic.new(publication: pub, format: format, canonical_topic_url: canonical)
    rescue URI::InvalidURIError
      nil
    end
  end
end
