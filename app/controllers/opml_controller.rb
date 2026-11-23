class OpmlController < ApplicationController
  skip_forgery_protection only: [ :export ]

  before_action :require_authentication, only: [ :import ]
  before_action :require_session_or_oauth_read!, only: [ :export ]

  def import
    xml = if params[:opml_file].respond_to?(:read)
      params[:opml_file].read
    else
      params[:opml_xml].to_s
    end

    import_rec = Opml::Import.enqueue(user: current_user, opml_xml: xml)
    redirect_to dashboard_path, notice: "OPML import queued (#{import_rec.total_count} feeds)."
  rescue Opml::Import::Error => e
    redirect_to dashboard_path, alert: "OPML import rejected: #{e.message}"
  end

  def export
    xml = Opml::Export.call(user: @export_user)
    send_data xml,
      filename: "open-news-#{@export_user.namespace}-subscriptions.opml",
      type: "text/x-opml; charset=utf-8",
      disposition: "attachment"
  end

  private

  def require_session_or_oauth_read!
    if signed_in?
      @export_user = current_user
      return
    end

    auth = request.headers["Authorization"].to_s
    scheme, raw = auth.split(" ", 2)
    if scheme&.casecmp("Bearer")&.zero? && raw.present?
      token = Doorkeeper::AccessToken.by_token(raw.strip)
      user = token&.accessible? && token.includes_scope?("feeds:read") ? User.find_by(id: token.resource_owner_id) : nil
      if user&.active?
        @export_user = user
        return
      end
    end

    head :unauthorized
  end
end
