require "nokogiri"
require "time"

module Feeds
  class Parse
    class ParseError < StandardError; end
    class UnsafeXmlError < ParseError; end

    # Strict XML parse options: network disabled, DTD loading disabled, entity expansion disabled.
    STRICT_XML_OPTIONS = Nokogiri::XML::ParseOptions::NONET | Nokogiri::XML::ParseOptions::NOBLANKS

    ParsedFeed = Data.define(
      :format,
      :title,
      :description,
      :site_url,
      :self_url,
      :websub_hub,
      :websub_topic,
      :rsscloud_endpoint,
      :rsscloud_protocol,
      :rsscloud_register_procedure,
      :items
    )

    RawItem = Data.define(
      :raw_id,
      :raw_url,
      :title,
      :author,
      :summary,
      :content_html,
      :published_at,
      :updated_at
    )

    def self.call(xml_string, headers: {}, base_url: nil)
      new(xml_string, headers: headers, base_url: base_url).call
    end

    def initialize(xml_string, headers: {}, base_url: nil)
      @xml_string = xml_string.to_s
      @headers = (headers || {}).transform_keys(&:downcase)
      @base_url = base_url
    end

    def call
      raise ParseError, "empty feed body" if @xml_string.strip.empty?
      guard_against_xxe!(@xml_string)

      doc = begin
        Nokogiri::XML(@xml_string, nil, nil, STRICT_XML_OPTIONS)
      rescue Nokogiri::XML::SyntaxError => e
        raise ParseError, "malformed XML: #{e.message}"
      end
      raise ParseError, "XML contains no root element" unless doc.root

      root_name = doc.root.name.downcase
      header_links = parse_link_headers(@headers["link"])

      case root_name
      when "rss", "rdf"
        parse_rss(doc, header_links)
      when "feed"
        parse_atom(doc, header_links)
      else
        raise ParseError, "unrecognized feed root element <#{doc.root.name}>"
      end
    end

    private

    def guard_against_xxe!(xml)
      # Reject XML documents declaring entities or external DTD subsets.
      if xml.match?(/<!ENTITY\b/i) || xml.match?(/<!DOCTYPE[^>]*(SYSTEM|PUBLIC|\[)/im)
        raise UnsafeXmlError, "XML DOCTYPE/ENTITY declarations are forbidden"
      end
    end

    def parse_rss(doc, header_links)
      channel = doc.root.at_xpath("./channel") || doc.root.at_xpath("//*[local-name()='channel']")
      raise ParseError, "RSS document missing <channel>" unless channel

      title = text_of(channel, "./*[local-name()='title']")
      description = text_of(channel, "./*[local-name()='description']")
      site_url = UrlNormalizer.resolve(@base_url, text_of(channel, "./*[local-name()='link' and not(@rel)]"))

      self_link = channel.xpath("./*[local-name()='link' and @rel='self']/@href").first&.value
      hub_link = channel.xpath("./*[local-name()='link' and @rel='hub']/@href").first&.value

      cloud_node = channel.at_xpath("./*[local-name()='cloud']")
      rsscloud_endpoint, rsscloud_protocol, rsscloud_reg_proc = extract_rsscloud(cloud_node)

      raw_items = (channel.xpath("./*[local-name()='item']").to_a.presence || doc.root.xpath("./*[local-name()='item']").to_a)
      items = raw_items.map { |node| parse_rss_item(node) }

      websub_hub = UrlNormalizer.resolve(@base_url, header_links["hub"] || hub_link)
      websub_topic = UrlNormalizer.resolve(@base_url, header_links["self"] || self_link)

      ParsedFeed.new(
        format: "rss",
        title: title,
        description: description,
        site_url: site_url,
        self_url: websub_topic,
        websub_hub: websub_hub,
        websub_topic: websub_topic,
        rsscloud_endpoint: rsscloud_endpoint,
        rsscloud_protocol: rsscloud_protocol,
        rsscloud_register_procedure: rsscloud_reg_proc,
        items: items
      )
    end

    def parse_rss_item(node)
      guid_node = node.at_xpath("./*[local-name()='guid']")
      guid = guid_node&.text&.strip.presence
      link = text_of(node, "./*[local-name()='link']")
      if link.blank? && guid.present? && guid_node["isPermaLink"] != "false" && guid.start_with?("http://", "https://")
        link = guid
      end

      content_encoded = text_of(node, "./*[local-name()='encoded']")
      description = text_of(node, "./*[local-name()='description']")
      author = text_of(node, "./*[local-name()='creator']") || text_of(node, "./*[local-name()='author']")

      pub_date = parse_time(text_of(node, "./*[local-name()='pubDate']") || text_of(node, "./*[local-name()='date']"))
      updated = parse_time(text_of(node, "./*[local-name()='updated']"))

      RawItem.new(
        raw_id: guid,
        raw_url: link,
        title: text_of(node, "./*[local-name()='title']"),
        author: author,
        summary: content_encoded.present? ? description : nil,
        content_html: content_encoded.presence || description,
        published_at: pub_date,
        updated_at: updated
      )
    end

    def parse_atom(doc, header_links)
      root = doc.root
      title = text_of(root, "./*[local-name()='title']")
      description = text_of(root, "./*[local-name()='subtitle']")

      alt_href = root.xpath("./*[local-name()='link' and (@rel='alternate' or not(@rel))]/@href").first&.value
      self_href = root.xpath("./*[local-name()='link' and @rel='self']/@href").first&.value
      hub_href = root.xpath("./*[local-name()='link' and @rel='hub']/@href").first&.value

      cloud_node = root.at_xpath("./*[local-name()='cloud']")
      rsscloud_endpoint, rsscloud_protocol, rsscloud_reg_proc = extract_rsscloud(cloud_node)

      items = root.xpath("./*[local-name()='entry']").map { |entry| parse_atom_entry(entry) }

      websub_hub = UrlNormalizer.resolve(@base_url, header_links["hub"] || hub_href)
      websub_topic = UrlNormalizer.resolve(@base_url, header_links["self"] || self_href)

      ParsedFeed.new(
        format: "atom",
        title: title,
        description: description,
        site_url: UrlNormalizer.resolve(@base_url, alt_href),
        self_url: websub_topic,
        websub_hub: websub_hub,
        websub_topic: websub_topic,
        rsscloud_endpoint: rsscloud_endpoint,
        rsscloud_protocol: rsscloud_protocol,
        rsscloud_register_procedure: rsscloud_reg_proc,
        items: items
      )
    end

    def parse_atom_entry(entry)
      entry_id = text_of(entry, "./*[local-name()='id']")
      link = entry.xpath("./*[local-name()='link' and (@rel='alternate' or not(@rel))]/@href").first&.value
      author = text_of(entry, "./*[local-name()='author']/*[local-name()='name']") ||
               text_of(entry, "./*[local-name()='author']")

      summary_node = entry.at_xpath("./*[local-name()='summary']")
      content_node = entry.at_xpath("./*[local-name()='content']")

      summary = extract_atom_text(summary_node)
      content = extract_atom_text(content_node)

      published = parse_time(text_of(entry, "./*[local-name()='published']"))
      updated = parse_time(text_of(entry, "./*[local-name()='updated']"))

      RawItem.new(
        raw_id: entry_id,
        raw_url: link,
        title: text_of(entry, "./*[local-name()='title']"),
        author: author,
        summary: summary,
        content_html: content.presence || summary,
        published_at: published || updated,
        updated_at: updated
      )
    end

    def extract_atom_text(node)
      return nil unless node

      if node["type"]&.downcase == "xhtml"
        node.inner_html.strip.presence
      else
        node.text.strip.presence
      end
    end

    def extract_rsscloud(node)
      return [ nil, nil, nil ] unless node

      domain = node["domain"]&.strip
      path = node["path"]&.strip
      port = node["port"]&.strip
      protocol = node["protocol"]&.strip.presence || "http-post"
      register_proc = node["registerProcedure"]&.strip.presence
      return [ nil, nil, nil ] if domain.blank? || path.blank?

      scheme = port == "443" ? "https" : "http"
      port_part = (port.present? && !%w[80 443].include?(port)) ? ":#{port}" : ""
      normalized_path = path.start_with?("/") ? path : "/#{path}"
      endpoint = UrlNormalizer.normalize("#{scheme}://#{domain}#{port_part}#{normalized_path}")
      [ endpoint, protocol, register_proc ]
    end

    def parse_link_headers(raw)
      result = {}
      return result if raw.blank?

      raw.to_s.split(",").each do |part|
        if (m = part.match(/<([^>]+)>.*?\brel\s*=\s*"?([^";\s]+)"?/i))
          url, rel = m[1].strip, m[2].downcase
          result[rel] ||= url
        end
      end
      result
    end

    def text_of(node, xpath)
      node.at_xpath(xpath)&.text&.strip.presence
    end

    def parse_time(raw)
      return nil if raw.blank?

      Time.parse(raw).utc
    rescue ArgumentError
      nil
    end
  end
end
