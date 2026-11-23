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

  # Upstream push protocol callbacks (Phase 2: WebSub subscriber & rssCloud consumer)
  get "/callbacks/websub/:token", to: "callbacks/web_sub#verify", as: :websub_callback
  post "/callbacks/websub/:token", to: "callbacks/web_sub#notify"
  get "/callbacks/rsscloud/:token", to: "callbacks/rss_cloud#verify", as: :rsscloud_callback
  post "/callbacks/rsscloud/:token", to: "callbacks/rss_cloud#notify"

  # Minimal server-rendered web UI
  root "dashboard#index"
  get "/dashboard", to: "dashboard#index", as: :dashboard

  get "/signup", to: "registrations#new", as: :signup
  post "/signup", to: "registrations#create"

  get "/login", to: "sessions#new", as: :login
  post "/login", to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout

  resources :subscriptions, only: [ :create, :destroy ]
  resources :documents, only: [ :index, :new, :create, :edit, :update, :destroy ]
  get "/feeds/:id", to: "feeds#show", as: :feed_diagnostics
  get "/items/:id", to: "items#show", as: :feed_item
  patch "/items/:id/state", to: "items#update_state", as: :update_feed_item_state

  post "/opml/import", to: "opml#import", as: :import_opml
  get "/opml/export", to: "opml#export", as: :export_opml

  get "/settings/connections", to: "oauth_connections#index", as: :oauth_connections
  delete "/settings/connections/:id", to: "oauth_connections#destroy", as: :revoke_oauth_connection

  # Public hosted publication, feeds, and Markdown/HTML documents (must remain last)
  namespace_constraint = /[a-zA-Z0-9][a-zA-Z0-9_-]{1,30}[a-zA-Z0-9]/
  get "/:namespace/feed.xml", to: "public_documents#rss", format: false, constraints: { namespace: namespace_constraint }, as: :public_rss_feed
  get "/:namespace/feed.atom", to: "public_documents#atom", format: false, constraints: { namespace: namespace_constraint }, as: :public_atom_feed
  get "/:namespace", to: "public_documents#publication", format: false, constraints: { namespace: namespace_constraint }, as: :public_publication
  get "/:namespace/*path", to: "public_documents#show", format: false, constraints: { namespace: namespace_constraint }, as: :public_document
end
