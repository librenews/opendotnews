module Sources
  module Adapters
    # Base contract for all content source adapters.
    # Future website or browser-based adapters implement this interface so they plug directly
    # into Feeds::Fetch -> Feeds::Ingest -> OutboxEvent -> Search without changing FeedItem.
    class Base
      def self.source_type
        raise NotImplementedError, "#{name} must define .source_type"
      end

      def initialize(fetcher: nil, **_opts)
        @fetcher = fetcher
      end

      # Fetch and normalize the remote source into a Sources::FetchResult.
      def fetch(_source)
        raise NotImplementedError, "#{self.class.name} must implement #fetch(source)"
      end

      # Parse and normalize an already-delivered payload (e.g. WebSub fat push or replay fixture).
      # Returns { items: [Sources::NormalizedItem], source_attributes: Hash, source_metadata: Hash, diagnostics: Hash }.
      def parse_payload(_raw_body, headers: {}, base_url: nil)
        raise NotImplementedError, "#{self.class.name} must implement #parse_payload"
      end
    end
  end
end
