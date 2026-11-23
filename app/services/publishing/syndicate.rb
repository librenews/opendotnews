require "nokogiri"
require "digest"
require "uri"

module Publishing
  # Generates RSS 2.0 and Atom 1.0 feeds for a hosted Publication, advertising both
  # WebSub hub/self links and rssCloud registration metadata.
  class Syndicate
    DEFAULT_LIMIT = 50

    FeedPayload = Data.define(:xml, :content_type, :etag, :last_modified, :link_header)

    def self.to_rss(publication, limit: DEFAULT_LIMIT)
      new(publication, limit: limit).to_rss
    end

    def self.to_atom(publication, limit: DEFAULT_LIMIT)
      new(publication, limit: limit).to_atom
    end

    def initialize(publication, limit: DEFAULT_LIMIT)
      @publication = publication
      @user = publication.user
      @limit = limit
      @base_url = OpenNews.config.app_base_url
      @base_uri = URI.parse(@base_url)
    end

    def to_rss
      docs = public_documents
      self_url = "#{@base_url}/#{@user.namespace}/feed.xml"
      hub_url = "#{@base_url}/websub/hub"
      site_url = "#{@base_url}/#{@user.namespace}"
      port = @base_uri.port || (@base_uri.scheme == "https" ? 443 : 80)

      builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.rss(
          "version" => "2.0",
          "xmlns:atom" => "http://www.w3.org/2005/Atom",
          "xmlns:content" => "http://purl.org/rss/1.0/modules/content/"
        ) do
          xml.channel do
            xml.title @publication.title.presence || @user.namespace
            xml.link site_url
            xml.description @publication.description.presence || "Published by @#{@user.namespace} on Open.News"
            xml.lastBuildDate((latest_timestamp(docs) || @publication.updated_at).utc.rfc2822)

            xml["atom"].link(href: self_url, rel: "self", type: "application/rss+xml")
            xml["atom"].link(href: hub_url, rel: "hub")
            xml.cloud(
              domain: @base_uri.host,
              port: port.to_s,
              path: "/rsscloud/pleaseNotify",
              registerProcedure: "",
              protocol: "http-post"
            )

            docs.each do |doc|
              rev = doc.current_revision
              next unless rev

              html = Publishing::Render.to_html(rev.markdown)
              summary = Publishing::Render.excerpt(rev.markdown)

              xml.item do
                xml.title doc.title
                xml.link doc.canonical_url
                xml.guid(doc.rss_guid, isPermaLink: "false")
                xml.pubDate((doc.published_at || doc.created_at).utc.rfc2822)
                xml.description summary
                xml["content"].encoded { xml.cdata(html) }
              end
            end
          end
        end
      end

      xml_str = builder.to_xml
      build_payload(xml_str, "application/rss+xml; charset=utf-8", docs, self_url, hub_url)
    end

    def to_atom
      docs = public_documents
      self_url = "#{@base_url}/#{@user.namespace}/feed.atom"
      hub_url = "#{@base_url}/websub/hub"
      site_url = "#{@base_url}/#{@user.namespace}"
      updated = latest_timestamp(docs) || @publication.updated_at

      builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.feed("xmlns" => "http://www.w3.org/2005/Atom") do
          xml.id "urn:uuid:#{@publication.id}"
          xml.title @publication.title.presence || @user.namespace
          xml.subtitle(@publication.description) if @publication.description.present?
          xml.updated updated.utc.iso8601
          xml.link(href: self_url, rel: "self", type: "application/atom+xml")
          xml.link(href: hub_url, rel: "hub")
          xml.link(href: site_url, rel: "alternate", type: "text/html")
          xml.author { xml.name "@#{@user.namespace}" }

          docs.each do |doc|
            rev = doc.current_revision
            next unless rev

            html = Publishing::Render.to_html(rev.markdown)
            summary = Publishing::Render.excerpt(rev.markdown)

            xml.entry do
              xml.id doc.rss_guid
              xml.title doc.title
              xml.link(href: doc.canonical_url, rel: "alternate", type: "text/html")
              xml.link(href: doc.markdown_url, rel: "alternate", type: "text/markdown")
              xml.published((doc.published_at || doc.created_at).utc.iso8601)
              xml.updated doc.updated_at.utc.iso8601
              xml.summary summary
              xml.content(html, type: "html")
            end
          end
        end
      end

      xml_str = builder.to_xml
      build_payload(xml_str, "application/atom+xml; charset=utf-8", docs, self_url, hub_url)
    end

    private

    def public_documents
      @publication.documents
        .publicly_visible
        .includes(:document_revisions, publication: :user)
        .order(Arel.sql("COALESCE(published_at, created_at) DESC, id DESC"))
        .limit(@limit)
        .to_a
    end

    def latest_timestamp(docs)
      docs.map(&:updated_at).compact.max
    end

    def build_payload(xml_str, content_type, docs, self_url, hub_url)
      etag = %(W/"#{Digest::SHA256.hexdigest(xml_str)[0, 32]}")
      last_mod = (latest_timestamp(docs) || @publication.updated_at).utc
      link_hdr = %(<#{hub_url}>; rel="hub", <#{self_url}>; rel="self")
      FeedPayload.new(
        xml: xml_str,
        content_type: content_type,
        etag: etag,
        last_modified: last_mod,
        link_header: link_hdr
      )
    end
  end
end
