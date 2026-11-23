module Sources
  class Registry
    class UnknownSourceTypeError < StandardError; end

    @adapters = {}

    class << self
      def register(source_type, adapter_class)
        @adapters[source_type.to_s] = adapter_class
      end

      def adapter_class_for(source_type)
        ensure_defaults!
        klass = @adapters[source_type.to_s]
        raise UnknownSourceTypeError, "No source adapter registered for #{source_type.inspect}" unless klass

        klass
      end

      def adapter_for(source, **opts)
        adapter_class_for(source.source_type.presence || "feed").new(**opts)
      end

      def registered_types
        ensure_defaults!
        @adapters.keys
      end

      def reset!
        @adapters = {}
        ensure_defaults!
      end

      private

      def ensure_defaults!
        @adapters["feed"] ||= Sources::Adapters::FeedAdapter
      end
    end
  end
end
