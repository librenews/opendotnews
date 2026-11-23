Rails.application.routes.draw do
  # Health probes
  get "/health/live", to: "health#live"
  get "/health/ready", to: "health#ready"

  # OAuth 2.1 Discovery (RFC 9728, RFC 8414) & Dynamic Client Registration (RFC 7591)
  get "/.well-known/oauth-protected-resource", to: "oauth_metadata#protected_resource"
  get "/.well-known/oauth-protected-resource/mcp", to: "oauth_metadata#protected_resource"
  get "/.well-known/oauth-authorization-server", to: "oauth_metadata#authorization_server"
  post "/oauth/register", to: "oauth_registrations#create"

  # Doorkeeper OAuth 2.1 endpoints (/oauth/authorize, /oauth/token, /oauth/revoke)
  use_doorkeeper

  # Remote MCP endpoint (Streamable HTTP)
  post "/mcp", to: "mcp#handle"
  get "/mcp", to: "mcp#method_not_allowed"

  # Minimal server-rendered web UI
  root "dashboard#index"
  get "/dashboard", to: "dashboard#index", as: :dashboard

  get "/signup", to: "registrations#new", as: :signup
  post "/signup", to: "registrations#create"

  get "/login", to: "sessions#new", as: :login
  post "/login", to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout

  resources :subscriptions, only: [ :create, :destroy ]
  get "/items/:id", to: "items#show", as: :feed_item

  post "/opml/import", to: "opml#import", as: :import_opml
  get "/opml/export", to: "opml#export", as: :export_opml

  get "/settings/connections", to: "oauth_connections#index", as: :oauth_connections
  delete "/settings/connections/:id", to: "oauth_connections#destroy", as: :revoke_oauth_connection
end
