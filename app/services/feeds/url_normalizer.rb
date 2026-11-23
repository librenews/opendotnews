require "uri"

module Feeds
  module UrlNormalizer
    module_function

    def normalize(raw_url)
      return nil if raw_url.blank?

      uri = URI.parse(raw_url.to_s.strip)
      return nil unless %w[http https].include?(uri.scheme&.downcase) && uri.host.present?

      uri.scheme = uri.scheme.downcase
      uri.host = uri.host.downcase
      uri.port = nil if (uri.scheme == "http" && uri.port == 80) || (uri.scheme == "https" && uri.port == 443)
      uri.fragment = nil
      uri.path = "/" if uri.path.blank?
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def resolve(base_url, href)
      return nil if href.blank?

      joined = if base_url.present?
        URI.join(base_url.to_s.strip, href.to_s.strip).to_s
      else
        href.to_s.strip
      end
      normalize(joined)
    rescue URI::InvalidURIError, ArgumentError
      nil
    end
  end
end
