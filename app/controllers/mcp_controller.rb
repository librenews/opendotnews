class McpController < ActionController::Base
  skip_forgery_protection

  before_action :validate_origin!
  before_action :authenticate_oauth_token!

  def handle
    body = request.raw_post
    if body.bytesize > OpenNews.config.opml_max_bytes + 65_536
      return render json: { jsonrpc: "2.0", id: nil, error: { code: -32600, message: "Request body too large" } }, status: :payload_too_large
    end

    rpc = JSON.parse(body)
    status, payload = Mcp::Dispatcher.new(user: @mcp_user, token: @mcp_token).call(rpc)

    if payload.nil?
      head status
    else
      render json: payload, status: status
    end
  rescue JSON::ParserError
    render json: { jsonrpc: "2.0", id: nil, error: { code: -32700, message: "Parse error" } }, status: :bad_request
  end

  def method_not_allowed
    response.set_header("Allow", "POST")
    head :method_not_allowed
  end

  private

  def validate_origin!
    origin = request.headers["Origin"].to_s.strip
    return if origin.blank?

    allowed = URI.parse(OpenNews.config.app_base_url)
    incoming = URI.parse(origin)
    same_origin = (allowed.scheme == incoming.scheme && allowed.host == incoming.host && allowed.port == incoming.port)
    unless same_origin
      render json: { error: "invalid_origin" }, status: :forbidden
    end
  rescue URI::InvalidURIError
    render json: { error: "invalid_origin" }, status: :forbidden
  end

  def authenticate_oauth_token!
    raw = extract_bearer_token
    if raw.blank?
      return render_unauthorized("missing_token")
    end

    token = Doorkeeper::AccessToken.by_token(raw)
    if token.nil? || !token.accessible?
      return render_unauthorized("invalid_token")
    end

    user = User.find_by(id: token.resource_owner_id)
    if user.nil? || !user.active?
      return render_unauthorized("account_disabled")
    end

    @mcp_token = token
    @mcp_user = user
    Current.oauth_token = token
    Current.user = user
  end

  def extract_bearer_token
    auth = request.headers["Authorization"].to_s
    scheme, token = auth.split(" ", 2)
    return nil unless scheme&.casecmp("Bearer")&.zero? && token.present?

    token.strip
  end

  def render_unauthorized(err)
    resource_meta = "#{OpenNews.config.app_base_url}/.well-known/oauth-protected-resource"
    response.set_header("WWW-Authenticate", %(Bearer error="#{err}", resource_metadata="#{resource_meta}"))
    render json: { error: err }, status: :unauthorized
  end
end
