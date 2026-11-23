module Sources
  module Adapters
    # Default adapter for RSS 2.0 and Atom 1.0 syndication feeds.
    class FeedAdapter < Base
      def self.source_type
        "feed"
      end

      def initialize(fetcher: nil, **_opts)
        super
        @fetcher = fetcher || Security::SafeHttpFetch.new
      end

      def fetch(source)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        resp = @fetcher.get(source.canonical_url, etag: source.etag, last_modified: source.last_modified)
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

        if resp.not_modified?
          return Sources::FetchResult.new(
            status: :not_modified,
            items: [],
            source_attributes: {},
            source_metadata: {},
            etag: resp.etag || source.etag,
            last_modified: resp.last_modified || source.last_modified,
            raw_body: nil,
            http_status: resp.status,
            duration_ms: duration_ms,
            response: resp,
            error: nil,
            diagnostics: {
              "http_status" => resp.status,
              "not_modified" => true,
              "redirect_count" => resp.redirect_chain.size
            }
          )
        end

        unless resp.success?
          return Sources::FetchResult.new(
            status: :error,
            items: [],
            source_attributes: {},
            source_metadata: {},
            etag: nil,
            last_modified: nil,
            raw_body: nil,
            http_status: resp.status,
            duration_ms: duration_ms,
            response: resp,
            error: "HTTP #{resp.status}",
            diagnostics: {
              "http_status" => resp.status,
              "redirect_count" => resp.redirect_chain.size,
              "content_type" => resp.content_type
            }
          )
        end

        parsed_payload = parse_payload(resp.body, headers: resp.headers, base_url: resp.final_url)
        diagnostics = parsed_payload[:diagnostics].merge(
          "http_status" => resp.status,
          "response_bytes" => resp.body.bytesize,
          "redirect_count" => resp.redirect_chain.size,
          "content_type" => resp.content_type
        )

        Sources::FetchResult.new(
          status: :ok,
          items: parsed_payload[:items],
          source_attributes: parsed_payload[:source_attributes],
          source_metadata: parsed_payload[:source_metadata],
          etag: resp.etag,
          last_modified: resp.last_modified,
          raw_body: resp.body,
          http_status: resp.status,
          duration_ms: duration_ms,
          response: resp,
          error: nil,
          diagnostics: diagnostics
        )
      rescue Feeds::Parse::ParseError, Security::SafeHttpFetch::Error => e
        duration_ms = started ? ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round : 0
        Sources::FetchResult.new(
          status: :error,
          items: [],
          source_attributes: {},
          source_metadata: {},
          etag: nil,
          last_modified: nil,
          raw_body: nil,
          http_status: 0,
          duration_ms: duration_ms,
          response: nil,
          error: e.message,
          diagnostics: { "error_class" => e.class.name }
        )
      end

      def parse_payload(raw_body, headers: {}, base_url: nil)
        parsed = Feeds::Parse.call(raw_body, headers: headers, base_url: base_url)
        items = Feeds::Normalize.call(parsed, feed_url: base_url)

        source_attributes = {
          title: parsed.title,
          description: parsed.description,
          site_url: parsed.site_url,
          format: parsed.format,
          discovered_websub_hub: parsed.websub_hub,
          discovered_websub_topic: parsed.websub_topic,
          discovered_rsscloud_endpoint: parsed.rsscloud_endpoint,
          discovered_rsscloud_protocol: parsed.rsscloud_protocol
        }

        diagnostics = {
          "format" => parsed.format,
          "parsed_item_count" => parsed.items.size,
          "normalized_item_count" => items.size,
          "websub_advertised" => parsed.websub_hub.present?,
          "rsscloud_advertised" => parsed.rsscloud_endpoint.present?
        }

        {
          items: items,
          source_attributes: source_attributes,
          source_metadata: {
            "self_url" => parsed.self_url,
            "rsscloud_register_procedure" => parsed.rsscloud_register_procedure
          }.compact,
          diagnostics: diagnostics
        }
      end
    end
  end
end
