require "nokogiri"

module Opml
  class Import
    class Error < StandardError; end
    class TooLargeError < Error; end
    class UnsafeXmlError < Error; end
    class InvalidOpmlError < Error; end

    MAX_STORED_ERRORS = 50
    STRICT_XML_OPTIONS = Nokogiri::XML::ParseOptions::NONET | Nokogiri::XML::ParseOptions::NOBLANKS

    OutlineEntry = Data.define(:url, :title, :folder, :html_url)

    def self.parse_outlines(opml_xml)
      xml = opml_xml.to_s
      if xml.bytesize > OpenNews.config.opml_max_bytes
        raise TooLargeError, "OPML exceeds maximum size of #{OpenNews.config.opml_max_bytes} bytes"
      end
      if xml.strip.empty?
        raise InvalidOpmlError, "OPML document is empty"
      end
      if xml.match?(/<!ENTITY\b/i) || xml.match?(/<!DOCTYPE[^>]*(SYSTEM|PUBLIC|\[)/im)
        raise UnsafeXmlError, "XML DOCTYPE/ENTITY declarations are forbidden"
      end

      doc = begin
        Nokogiri::XML(xml, nil, nil, STRICT_XML_OPTIONS)
      rescue Nokogiri::XML::SyntaxError => e
        raise InvalidOpmlError, "Malformed OPML XML: #{e.message}"
      end
      raise InvalidOpmlError, "Missing <opml> root element" unless doc.root&.name&.downcase == "opml"

      body = doc.root.at_xpath("./*[local-name()='body']")
      raise InvalidOpmlError, "Missing <body> element in OPML" unless body

      outlines = []
      walk_outlines(body, nil, outlines)

      if outlines.size > OpenNews.config.opml_max_feeds
        raise TooLargeError, "OPML contains #{outlines.size} feeds, exceeding limit of #{OpenNews.config.opml_max_feeds}"
      end

      outlines
    end

    # Validates synchronously, creates OpmlImport record without persisting raw XML indefinitely,
    # and enqueues batched processing.
    def self.enqueue(user:, opml_xml:)
      outlines = parse_outlines(opml_xml)
      import = OpmlImport.create!(
        user: user,
        status: "pending",
        total_count: outlines.size
      )

      serialized = outlines.map do |o|
        { "url" => o.url, "title" => o.title, "folder" => o.folder, "html_url" => o.html_url }
      end
      Opml::ImportJob.perform_async(import.id, serialized)
      import
    end

    # Synchronous execution used by Opml::ImportJob and tests.
    def self.process!(opml_import, serialized_outlines, enqueue_fetches: true)
      opml_import.update!(status: "processing", started_at: Time.current)

      user = opml_import.user
      seen_urls = {}
      success = 0
      skipped = 0
      errors = []

      serialized_outlines.each do |entry|
        raw_url = entry["url"].to_s.strip
        norm = Feeds::UrlNormalizer.normalize(raw_url)
        unless norm
          errors << { "url" => raw_url, "error" => "invalid_url" }
          next
        end

        if seen_urls[norm]
          skipped += 1
          next
        end
        seen_urls[norm] = true

        begin
          # Validate URL safety upfront (no private/loopback feeds unless explicitly allowed).
          uri = URI.parse(norm)
          if !OpenNews.config.allow_private_http_fetch &&
             (uri.host == "localhost" || Security::SafeHttpFetch.blocked_ip?(uri.host))
            # Only reject if host is literal IP or localhost; DNS is checked during FetchJob.
            if uri.host == "localhost" || (IPAddr.new(uri.host.delete_prefix("[").delete_suffix("]")) rescue false)
              errors << { "url" => raw_url, "error" => "ssrf_blocked" }
              next
            end
          end

          feed = Feed.find_by(canonical_url: norm) || FeedAlias.find_by(url: norm)&.feed
          feed ||= Feed.find_or_create_by!(canonical_url: norm) do |f|
            f.title = entry["title"].presence
            f.site_url = Feeds::UrlNormalizer.normalize(entry["html_url"])
            f.status = "active"
            f.next_fetch_at = Time.current
          end

          existing = UserFeedSubscription.active.find_by(user_id: user.id, feed_id: feed.id)
          if existing
            skipped += 1
          else
            UserFeedSubscription.create!(
              user: user,
              feed: feed,
              folder_name: entry["folder"].presence,
              subscribed_at: Time.current
            )
            success += 1
            Feeds::FetchJob.perform_async(feed.id) if enqueue_fetches && feed.last_fetched_at.nil?
          end
        rescue ActiveRecord::RecordNotUnique
          skipped += 1
        rescue StandardError => e
          errors << { "url" => raw_url, "error" => e.message.to_s.truncate(200) }
        end
      end

      opml_import.update!(
        status: "completed",
        total_count: serialized_outlines.size,
        success_count: success,
        skipped_count: skipped,
        error_count: errors.size,
        error_summary: errors.first(MAX_STORED_ERRORS),
        completed_at: Time.current
      )

      AuditLog.record!(
        action: "opml.imported",
        user: user,
        resource_type: "OpmlImport",
        resource_id: opml_import.id,
        scope: "feeds:write",
        metadata: { total: serialized_outlines.size, success: success, skipped: skipped, errors: errors.size }
      )

      opml_import
    rescue StandardError => e
      opml_import.update!(
        status: "failed",
        error_count: opml_import.error_count + 1,
        error_summary: [ { "error" => e.message.to_s.truncate(300) } ],
        completed_at: Time.current
      )
      raise
    end

    def self.walk_outlines(parent_node, current_folder, out)
      parent_node.xpath("./*[local-name()='outline']").each do |node|
        xml_url = attr_ci(node, "xmlurl")
        title = attr_ci(node, "title") || attr_ci(node, "text")
        html_url = attr_ci(node, "htmlurl")

        if xml_url.present?
          out << OutlineEntry.new(
            url: xml_url.strip,
            title: title&.strip.presence,
            folder: current_folder,
            html_url: html_url&.strip.presence
          )
        else
          folder_name = title&.strip.presence || current_folder
          walk_outlines(node, folder_name, out)
        end
      end
    end
    private_class_method :walk_outlines

    def self.attr_ci(node, target_downcased)
      node.attributes.each do |name, attr|
        return attr.value if name.downcase == target_downcased
      end
      nil
    end
    private_class_method :attr_ci
  end
end
