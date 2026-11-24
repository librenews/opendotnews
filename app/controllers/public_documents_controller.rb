require "digest"

class PublicDocumentsController < ApplicationController
  skip_before_action :resume_session

  before_action :load_publication!

  # GET /:namespace — public publication index (enables RSS/Atom autodiscovery from namespace URL!)
  def publication
    @documents = @publication.documents
      .publicly_visible
      .order(Arel.sql("COALESCE(published_at, created_at) DESC, id DESC"))
      .limit(50)
    @rss_url = "#{OpenNews.config.app_base_url}/#{@owner.namespace}/feed.xml"
    @atom_url = "#{OpenNews.config.app_base_url}/#{@owner.namespace}/feed.atom"
    render :publication, layout: "public"
  end

  # GET /:namespace/feed.xml
  def rss
    serve_feed(Publishing::Syndicate.to_rss(@publication))
  end

  # GET /:namespace/feed.atom
  def atom
    serve_feed(Publishing::Syndicate.to_atom(@publication))
  end

  # GET /:namespace/*path (supports Accept: text/markdown, default safe HTML, and .md alias)
  def show
    raw_path = params[:path].to_s
    md_alias = raw_path.downcase.end_with?(".md")
    lookup_path = md_alias ? raw_path[0...-3] : raw_path

    begin
      norm_path = Publishing::PathNormalizer.normalize!(lookup_path)
    rescue Publishing::PathNormalizer::InvalidPathError
      return head :not_found
    end

    @document = Document.find_by(publication_id: @publication.id, path: norm_path)
    return head :not_found unless @document
    return head :unavailable_for_legal_reasons if @document.moderated?
    return head :gone if @document.deleted?
    return head :not_found unless @document.public?

    @revision = if params[:revision].present?
      @document.revision(params[:revision])
    else
      @document.current_revision
    end
    return head :not_found unless @revision

    wants_markdown = md_alias || prefers_markdown?(request.headers["Accept"])
    last_mod = (@revision.created_at || @document.updated_at).utc

    response.set_header("Vary", "Accept")
    response.set_header("Link", %(<#{@document.canonical_url}>; rel="canonical"))
    response.set_header("Cache-Control", "public, max-age=60")

    if wants_markdown
      etag = %(W/"md-#{@revision.sha256[0, 32]}")
      return if fresh_response?(etag: etag, last_modified: last_mod)

      render plain: @revision.markdown, content_type: "text/markdown; charset=utf-8"
    else
      html_body = Publishing::Render.to_html(@revision.markdown)
      etag = %(W/"html-#{Digest::SHA256.hexdigest("#{@document.title}\0#{@revision.sha256}")[0, 32]}")
      return if fresh_response?(etag: etag, last_modified: last_mod)

      @rendered_html = html_body
      @rss_url = "#{OpenNews.config.app_base_url}/#{@owner.namespace}/feed.xml"
      @atom_url = "#{OpenNews.config.app_base_url}/#{@owner.namespace}/feed.atom"
      render :show, layout: "public"
    end
  end

  private

  def load_publication!
    ns = params[:namespace].to_s.strip.downcase
    return head(:not_found) if User::RESERVED_NAMESPACES.include?(ns)

    @owner = User.find_by("LOWER(namespace) = ?", ns)
    return head(:not_found) unless @owner&.active?

    @publication = @owner.default_publication
    return head(:not_found) unless @publication&.visibility == "public"
  end

  def serve_feed(payload)
    response.set_header("Link", payload.link_header)
    response.set_header("Cache-Control", "public, max-age=60")
    return if fresh_response?(etag: payload.etag, last_modified: payload.last_modified)

    render plain: payload.xml, content_type: payload.content_type
  end

  def fresh_response?(etag:, last_modified:)
    response.set_header("ETag", etag)
    response.set_header("Last-Modified", last_modified.httpdate)

    inm = request.headers["If-None-Match"].to_s.strip
    if inm.present? && (inm == etag || inm == "*")
      head :not_modified
      return true
    end

    ims = request.headers["If-Modified-Since"].to_s.strip
    if ims.present?
      begin
        if last_modified.change(usec: 0) <= Time.httpdate(ims)
          head :not_modified
          return true
        end
      rescue ArgumentError
        nil
      end
    end

    false
  end

  # RFC 9110 Accept negotiation: serve Markdown when text/markdown is explicitly requested
  # with q-value >= text/html; serve HTML for browsers and wildcard */*.
  def prefers_markdown?(accept_header)
    return false if accept_header.blank?

    md_q = nil
    html_q = nil

    accept_header.to_s.split(",").each do |part|
      media, *params = part.split(";").map(&:strip)
      next if media.blank?

      q = 1.0
      params.each do |p|
        if p.downcase.start_with?("q=")
          q = p.split("=", 2).last.to_f
        end
      end

      case media.downcase
      when "text/markdown", "text/x-markdown"
        md_q = [ md_q || 0.0, q ].max
      when "text/html", "application/xhtml+xml"
        html_q = [ html_q || 0.0, q ].max
      end
    end

    return false if md_q.nil? || md_q <= 0.0

    html_q.nil? || md_q >= html_q
  end
end
