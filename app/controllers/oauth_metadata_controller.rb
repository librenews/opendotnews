class OauthMetadataController < ActionController::Base
  SCOPES = %w[feeds:read feeds:write documents:read documents:write].freeze

  # RFC 9728 — OAuth 2.0 Protected Resource Metadata
  def protected_resource
    base = OpenNews.config.app_base_url
    render json: {
      resource: "#{base}/mcp",
      authorization_servers: [ base ],
      scopes_supported: SCOPES,
      bearer_methods_supported: %w[header]
    }
  end

  # RFC 8414 — OAuth 2.0 Authorization Server Metadata
  def authorization_server
    base = OpenNews.config.app_base_url
    render json: {
      issuer: base,
      authorization_endpoint: "#{base}/oauth/authorize",
      token_endpoint: "#{base}/oauth/token",
      revocation_endpoint: "#{base}/oauth/revoke",
      registration_endpoint: "#{base}/oauth/register",
      response_types_supported: %w[code],
      grant_types_supported: %w[authorization_code refresh_token],
      code_challenge_methods_supported: %w[S256],
      token_endpoint_auth_methods_supported: %w[none client_secret_post client_secret_basic],
      scopes_supported: SCOPES
    }
  end
end
