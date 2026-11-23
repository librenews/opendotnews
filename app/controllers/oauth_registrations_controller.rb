class OauthRegistrationsController < ActionController::Base
  skip_forgery_protection

  ALLOWED_SCOPES = %w[feeds:read feeds:write documents:read documents:write].freeze

  # RFC 7591 — OAuth 2.0 Dynamic Client Registration for MCP clients (Dots, Nods, etc.)
  def create
    payload = JSON.parse(request.raw_post.presence || "{}")
    client_name = payload["client_name"].to_s.strip.presence || "MCP Client"
    redirect_uris = Array(payload["redirect_uris"]).map(&:to_s).map(&:strip).reject(&:blank?)

    if redirect_uris.empty?
      return render json: { error: "invalid_redirect_uri", error_description: "redirect_uris must be a non-empty array" }, status: :bad_request
    end

    unless redirect_uris.all? { |u| valid_redirect_uri?(u) }
      return render json: { error: "invalid_redirect_uri", error_description: "All redirect_uris must use https or loopback http" }, status: :bad_request
    end

    auth_method = payload["token_endpoint_auth_method"].to_s.presence || "none"
    confidential = (auth_method != "none")

    requested_scopes = payload["scope"].to_s.split(/\s+/).select { |s| ALLOWED_SCOPES.include?(s) }
    scopes_str = (requested_scopes.presence || ALLOWED_SCOPES).join(" ")

    app = Doorkeeper::Application.create!(
      name: client_name.truncate(120),
      redirect_uri: redirect_uris.join("\n"),
      scopes: scopes_str,
      confidential: confidential
    )

    resp = {
      client_id: app.uid,
      client_name: app.name,
      redirect_uris: redirect_uris,
      grant_types: %w[authorization_code refresh_token],
      response_types: %w[code],
      token_endpoint_auth_method: confidential ? "client_secret_post" : "none",
      scope: app.scopes.to_s,
      client_id_issued_at: app.created_at.to_i
    }
    resp[:client_secret] = app.plaintext_secret || app.secret if confidential

    render json: resp, status: :created
  rescue JSON::ParserError
    render json: { error: "invalid_client_metadata", error_description: "Malformed JSON" }, status: :bad_request
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "invalid_client_metadata", error_description: e.message }, status: :bad_request
  end

  private

  def valid_redirect_uri?(raw)
    uri = URI.parse(raw)
    return false if uri.host.blank? || uri.fragment.present?

    scheme = uri.scheme&.downcase
    return true if scheme == "https"
    return true if scheme == "http" && %w[localhost 127.0.0.1 ::1].include?(uri.host.downcase)

    false
  rescue URI::InvalidURIError
    false
  end
end
