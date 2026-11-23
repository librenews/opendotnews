module Mcp
  class ToolError < StandardError
    attr_reader :code, :details

    def initialize(code, message, details: nil)
      super(message)
      @code = code
      @details = details
    end
  end

  module Tools
    class Base
      def self.tool_name
        raise NotImplementedError
      end

      def self.description
        raise NotImplementedError
      end

      def self.required_scope
        raise NotImplementedError
      end

      def self.input_schema
        { type: "object", properties: {}, additionalProperties: false }
      end

      def self.definition
        {
          name: tool_name,
          description: description,
          inputSchema: input_schema
        }
      end

      def initialize(user:, token: nil)
        @user = user
        @token = token
      end

      def call(_args)
        raise NotImplementedError
      end

      protected

      def serialize_feed(feed)
        {
          feed_id: feed.id,
          canonical_url: feed.canonical_url,
          site_url: feed.site_url,
          title: feed.title,
          format: feed.format,
          status: feed.status,
          last_fetched_at: feed.last_fetched_at&.iso8601,
          last_changed_at: feed.last_changed_at&.iso8601,
          fetch_failure_count: feed.fetch_failure_count,
          last_error: feed.last_error
        }.compact
      end

      def serialize_item_summary(item)
        {
          item_id: item.id,
          feed_id: item.feed_id,
          feed_title: item.feed&.title,
          title: item.title,
          author: item.author,
          permalink: item.external_url,
          published_at: item.published_at&.iso8601,
          first_seen_at: item.first_seen_at&.iso8601,
          revision_number: item.current_revision_number,
          summary: (item.summary_text.presence || item.content_text.to_s.truncate(400))
        }.compact
      end
    end

    class SubscribeFeed < Base
      def self.tool_name = "subscribe_feed"
      def self.required_scope = "feeds:write"
      def self.description = "Subscribe to an RSS/Atom feed or discover feeds from a website URL. Idempotent; returns choices if a site advertises multiple feeds."
      def self.input_schema
        {
          type: "object",
          required: %w[url],
          properties: {
            url: { type: "string", description: "Feed URL or website URL to discover a feed from" },
            folder: { type: "string", description: "Optional folder/group name" }
          },
          additionalProperties: false
        }
      end

      def call(args)
        url = args["url"].to_s.strip
        raise ToolError.new("invalid_url", "url parameter is required") if url.blank?

        res = Subscriptions::Subscribe.call(user: @user, url: url, folder: args["folder"])
        if res.selection_required?
          return {
            status: "selection_required",
            error_code: "ambiguous_feed",
            message: res.error,
            candidates: res.candidates.map { |c| { url: c.url, title: c.title, mime_type: c.mime_type }.compact }
          }
        end

        unless res.ok?
          raise ToolError.new(res.error_code || "feed_not_found", res.error || "Failed to subscribe")
        end

        {
          status: res.already_subscribed ? "already_subscribed" : "subscribed",
          subscription_id: res.subscription.id,
          folder: res.subscription.folder_name,
          feed: serialize_feed(res.feed)
        }.compact
      end
    end

    class UnsubscribeFeed < Base
      def self.tool_name = "unsubscribe_feed"
      def self.required_scope = "feeds:write"
      def self.description = "Unsubscribe the authenticated user from a feed by feed_id."
      def self.input_schema
        {
          type: "object",
          required: %w[feed_id],
          properties: {
            feed_id: { type: "string", description: "UUID of the feed to unsubscribe from" }
          },
          additionalProperties: false
        }
      end

      def call(args)
        feed_id = args["feed_id"].to_s.strip
        raise ToolError.new("invalid_request", "feed_id is required") if feed_id.blank?

        res = Subscriptions::Unsubscribe.call(user: @user, feed_id: feed_id)
        { status: "unsubscribed", feed_id: feed_id, removed: res.unsubscribed }
      end
    end

    class ListSubscriptions < Base
      def self.tool_name = "list_subscriptions"
      def self.required_scope = "feeds:read"
      def self.description = "List the authenticated user's active feed subscriptions and feed health."
      def self.input_schema
        {
          type: "object",
          properties: {
            cursor: { type: "string", description: "Opaque pagination cursor" },
            limit: { type: "integer", minimum: 1, maximum: 100 }
          },
          additionalProperties: false
        }
      end

      def call(args)
        limit = (args["limit"].nil? || args["limit"].to_i <= 0) ? 50 : args["limit"].to_i.clamp(1, 100)
        offset = decode_offset(args["cursor"])

        rows = UserFeedSubscription.active
          .includes(:feed)
          .where(user_id: @user.id)
          .order(subscribed_at: :desc, id: :desc)
          .offset(offset)
          .limit(limit + 1)
          .to_a

        has_more = rows.size > limit
        rows = rows.first(limit)

        {
          subscriptions: rows.map do |sub|
            {
              subscription_id: sub.id,
              folder: sub.folder_name,
              subscribed_at: sub.subscribed_at.iso8601,
              feed: serialize_feed(sub.feed)
            }.compact
          end,
          next_cursor: has_more ? Base64.urlsafe_encode64((offset + limit).to_s, padding: false) : nil,
          has_more: has_more
        }
      end

      private

      def decode_offset(raw)
        return 0 if raw.blank?

        n = Integer(Base64.urlsafe_decode64(raw.to_s), 10)
        n >= 0 ? n : 0
      rescue ArgumentError
        0
      end
    end

    class ListFeedItems < Base
      def self.tool_name = "list_feed_items"
      def self.required_scope = "feeds:read"
      def self.description = "List newest archived feed items across the user's subscribed feeds."
      def self.input_schema
        {
          type: "object",
          properties: {
            feed_id: { type: "string" },
            since: { type: "string", description: "ISO-8601 lower bound" },
            until: { type: "string", description: "ISO-8601 upper bound" },
            cursor: { type: "string" },
            limit: { type: "integer", minimum: 1, maximum: 100 }
          },
          additionalProperties: false
        }
      end

      def call(args)
        res = Feeds::ListItems.call(
          user: @user,
          feed_id: args["feed_id"],
          since: args["since"],
          until_time: args["until"],
          cursor: args["cursor"],
          limit: args["limit"]
        )
        {
          items: res.items.map { |i| serialize_item_summary(i) },
          next_cursor: res.next_cursor,
          has_more: res.has_more
        }
      end
    end

    class GetFeedItem < Base
      def self.tool_name = "get_feed_item"
      def self.required_scope = "feeds:read"
      def self.description = "Retrieve full stored details of a feed item from a feed the user subscribes to."
      def self.input_schema
        {
          type: "object",
          required: %w[item_id],
          properties: {
            item_id: { type: "string" }
          },
          additionalProperties: false
        }
      end

      def call(args)
        item_id = args["item_id"].to_s.strip
        raise ToolError.new("invalid_request", "item_id is required") if item_id.blank?

        authorized_feed_ids = UserFeedSubscription.active.where(user_id: @user.id).select(:feed_id)
        item = FeedItem.visible.includes(:feed).where(feed_id: authorized_feed_ids).find_by(id: item_id)
        raise ToolError.new("not_found", "Feed item not found or not accessible") unless item

        serialize_item_summary(item).merge(
          external_id: item.external_id,
          feed_url: item.feed&.canonical_url,
          source_updated_at: item.source_updated_at&.iso8601,
          content_text: item.content_text.to_s.truncate(20_000),
          content_html_sanitized: item.content_html_sanitized.to_s.truncate(20_000)
        ).compact
      end
    end

    class SearchItems < Base
      def self.tool_name = "search_items"
      def self.required_scope = "feeds:read"
      def self.description = "Full-text search across items archived from the user's subscribed feeds."
      def self.input_schema
        {
          type: "object",
          required: %w[query],
          properties: {
            query: { type: "string" },
            feed_id: { type: "string" },
            since: { type: "string" },
            until: { type: "string" },
            sort: { type: "string", enum: %w[relevance newest] },
            cursor: { type: "string" },
            limit: { type: "integer", minimum: 1, maximum: 100 }
          },
          additionalProperties: false
        }
      end

      def call(args)
        query = args["query"].to_s.strip
        raise ToolError.new("invalid_request", "query is required") if query.blank?

        res = Search::Items.call(
          user: @user,
          query: query,
          feed_id: args["feed_id"],
          since: args["since"],
          until_time: args["until"],
          sort: args["sort"] || "relevance",
          limit: args["limit"],
          cursor: args["cursor"]
        )
        {
          items: res.items.map { |i| serialize_item_summary(i) },
          next_cursor: res.next_cursor,
          has_more: res.has_more
        }
      end
    end

    class GetUpdates < Base
      def self.tool_name = "get_updates"
      def self.required_scope = "feeds:read"
      def self.description = "Poll durable per-user inbox events in ascending monotonic cursor order."
      def self.input_schema
        {
          type: "object",
          properties: {
            after_cursor: { type: "integer", minimum: 0 },
            feed_id: { type: "string" },
            limit: { type: "integer", minimum: 1, maximum: 100 },
            include_content: { type: "boolean" }
          },
          additionalProperties: false
        }
      end

      def call(args)
        res = Inbox::FetchUpdates.call(
          user: @user,
          after_cursor: args["after_cursor"],
          feed_id: args["feed_id"],
          limit: args["limit"],
          include_content: args["include_content"]
        )
        if res.cursor_expired?
          raise ToolError.new("cursor_expired", res.error, details: { earliest_available_cursor: res.earliest_available_cursor })
        end

        {
          events: res.events,
          next_cursor: res.next_cursor,
          has_more: res.has_more
        }
      end
    end

    class ImportOpml < Base
      def self.tool_name = "import_opml"
      def self.required_scope = "feeds:write"
      def self.description = "Validate a bounded OPML 1.0/2.0 XML document and enqueue asynchronous feed subscription import."
      def self.input_schema
        {
          type: "object",
          required: %w[opml_xml],
          properties: {
            opml_xml: { type: "string", description: "OPML XML document (max 2 MB, 2000 feeds)" }
          },
          additionalProperties: false
        }
      end

      def call(args)
        xml = args["opml_xml"].to_s
        import = Opml::Import.enqueue(user: @user, opml_xml: xml)
        {
          import_id: import.id,
          status: import.status,
          total_count: import.total_count
        }
      rescue Opml::Import::Error => e
        raise ToolError.new("invalid_opml", e.message)
      end
    end

    class GetOpmlImportStatus < Base
      def self.tool_name = "get_opml_import_status"
      def self.required_scope = "feeds:read"
      def self.description = "Check status and per-feed error summary for a user-owned OPML import."
      def self.input_schema
        {
          type: "object",
          required: %w[import_id],
          properties: {
            import_id: { type: "string" }
          },
          additionalProperties: false
        }
      end

      def call(args)
        import = OpmlImport.find_by(id: args["import_id"], user_id: @user.id)
        raise ToolError.new("not_found", "OPML import not found") unless import

        {
          import_id: import.id,
          status: import.status,
          total_count: import.total_count,
          success_count: import.success_count,
          skipped_count: import.skipped_count,
          error_count: import.error_count,
          error_summary: import.error_summary,
          completed_at: import.completed_at&.iso8601
        }.compact
      end
    end

    class ExportOpml < Base
      MAX_INLINE_OPML_BYTES = 512 * 1024

      def self.tool_name = "export_opml"
      def self.required_scope = "feeds:read"
      def self.description = "Export the user's active feed subscriptions as OPML 2.0 XML (or return an authenticated export URL if large)."
      def self.input_schema
        { type: "object", properties: {}, additionalProperties: false }
      end

      def call(_args)
        xml = Opml::Export.call(user: @user)
        if xml.bytesize <= MAX_INLINE_OPML_BYTES
          { opml_xml: xml, bytes: xml.bytesize }
        else
          {
            export_url: "#{OpenNews.config.app_base_url}/opml/export",
            bytes: xml.bytesize,
            note: "OPML exceeds inline limit; fetch export_url with your Bearer token"
          }
        end
      end
    end
  end
end
