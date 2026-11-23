Doorkeeper.configure do
  orm :active_record
  base_controller "ApplicationController"

  resource_owner_authenticator do
    user = Current.user
    if user&.active?
      user
    else
      session[:return_to] = request.fullpath
      redirect_to login_path
    end
  end

  admin_authenticator do
    user = Current.user
    if user&.active?
      user
    else
      redirect_to login_path
    end
  end

  # Hash access and refresh tokens at rest (SHA-256) so database dumps cannot replay bearer tokens.
  hash_token_secrets

  # OAuth 2.1 authorization code + PKCE + refresh tokens for remote MCP clients.
  grant_flows %w[authorization_code]
  use_refresh_token
  access_token_expires_in 2.hours
  authorization_code_expires_in 10.minutes

  # Scopes per Open.News spec Section 10.1
  default_scopes "feeds:read"
  optional_scopes "feeds:write", "documents:read", "documents:write"
  enforce_configured_scopes

  # Allow loopback HTTP redirects for local MCP clients while requiring HTTPS for remote callbacks.
  force_ssl_in_redirect_uri { |uri| !%w[localhost 127.0.0.1 ::1].include?(uri.host) && !Rails.env.local? }

  skip_authorization do |_resource_owner, _client|
    false
  end
end
