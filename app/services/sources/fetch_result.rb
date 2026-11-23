module Sources
  # Standard result contract returned by every Sources::Adapters::Base implementation.
  FetchResult = Data.define(
    :status,
    :items,
    :source_attributes,
    :source_metadata,
    :etag,
    :last_modified,
    :raw_body,
    :http_status,
    :duration_ms,
    :response,
    :error,
    :diagnostics
  ) do
    def ok?
      status == :ok
    end

    def not_modified?
      status == :not_modified
    end

    def error?
      status == :error
    end
  end
end
