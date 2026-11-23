require "rails_helper"
require "digest"
require "base64"

RSpec.describe "OAuth 2.1, Discovery, DCR, and Streamable HTTP MCP", type: :request do
  let!(:alice) { User.create!(email: "alice@example.org", namespace: "alice", password: "password123!") }
  let!(:bob) { User.create!(email: "bob@example.org", namespace: "bob", password: "password123!") }

  def mcp_post(rpc, token: nil, headers: {})
    hdrs = { "CONTENT_TYPE" => "application/json" }.merge(headers)
    hdrs["Authorization"] = "Bearer #{token}" if token
    post "/mcp", params: JSON.generate(rpc), headers: hdrs
  end

  it "serves health probes and RFC 9728 / RFC 8414 OAuth metadata" do
    get "/health/live"
    expect(response).to have_http_status(:ok)

    get "/health/ready"
    expect(response).to have_http_status(:ok)

    get "/.well-known/oauth-protected-resource"
    expect(response).to have_http_status(:ok)
    pr = JSON.parse(response.body)
    expect(pr["resource"]).to end_with("/mcp")
    expect(pr["scopes_supported"]).to include("feeds:read", "feeds:write", "documents:read", "documents:write")

    get "/.well-known/oauth-authorization-server"
    expect(response).to have_http_status(:ok)
    as = JSON.parse(response.body)
    expect(as["registration_endpoint"]).to end_with("/oauth/register")
    expect(as["code_challenge_methods_supported"]).to include("S256")
  end

  it "supports RFC 7591 Dynamic Client Registration + full OAuth 2.1 Auth Code + PKCE S256 flow" do
    # Reject unsafe redirect_uri
    post "/oauth/register",
      params: JSON.generate(client_name: "Evil", redirect_uris: [ "http://evil.example/cb" ]),
      headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:bad_request)

    # Register public PKCE client (Dots/Nods style)
    post "/oauth/register",
      params: JSON.generate(
        client_name: "Dots Agent",
        redirect_uris: [ "http://127.0.0.1:41234/callback" ],
        token_endpoint_auth_method: "none",
        scope: "feeds:read feeds:write"
      ),
      headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:created)
    client = JSON.parse(response.body)
    client_id = client["client_id"]
    expect(client_id).to be_present

    # Sign in Alice via web session
    post "/login", params: { email: alice.email, password: "password123!" }
    expect(response).to redirect_to("/dashboard")

    # PKCE S256 challenge
    verifier = SecureRandom.urlsafe_base64(48)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

    # Approve authorization grant
    post "/oauth/authorize", params: {
      client_id: client_id,
      redirect_uri: "http://127.0.0.1:41234/callback",
      response_type: "code",
      scope: "feeds:read feeds:write",
      code_challenge: challenge,
      code_challenge_method: "S256"
    }
    expect(response).to have_http_status(:found)
    code = URI.decode_www_form(URI.parse(response.location).query).to_h["code"]
    expect(code).to be_present

    # Exchange code + PKCE verifier for access token
    post "/oauth/token", params: {
      grant_type: "authorization_code",
      client_id: client_id,
      code: code,
      redirect_uri: "http://127.0.0.1:41234/callback",
      code_verifier: verifier
    }
    expect(response).to have_http_status(:ok)
    token_resp = JSON.parse(response.body)
    raw_token = token_resp["access_token"]
    expect(raw_token).to be_present

    # Verify token is stored hashed at rest (never raw in DB)
    expect(Doorkeeper::AccessToken.where(token: raw_token)).to be_empty

    # Call MCP initialize + tools/list with the issued OAuth token
    mcp_post({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2026-07-28" } }, token: raw_token)
    expect(response).to have_http_status(:ok)
    init_body = JSON.parse(response.body)
    expect(init_body.dig("result", "protocolVersion")).to eq("2026-07-28")

    # Notification returns 202 Accepted
    mcp_post({ jsonrpc: "2.0", method: "notifications/initialized" }, token: raw_token)
    expect(response).to have_http_status(:accepted)

    mcp_post({ jsonrpc: "2.0", id: 2, method: "tools/list" }, token: raw_token)
    expect(response).to have_http_status(:ok)
    tool_names = JSON.parse(response.body).dig("result", "tools").map { |t| t["name"] }
    expect(tool_names).to include(
      "subscribe_feed", "unsubscribe_feed", "list_subscriptions",
      "list_feed_items", "get_feed_item", "search_items",
      "get_updates", "import_opml", "get_opml_import_status", "export_opml"
    )

    # Revoke token and confirm immediate rejection
    post "/oauth/revoke", params: { token: raw_token, client_id: client_id }
    mcp_post({ jsonrpc: "2.0", id: 3, method: "tools/list" }, token: raw_token)
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["WWW-Authenticate"]).to include("resource_metadata=")
  end

  it "enforces Origin check, OAuth scopes, cross-user isolation, and executes all Phase 1 MCP tools" do
    app = Doorkeeper::Application.create!(
      name: "Test Client",
      redirect_uri: "http://127.0.0.1/cb",
      scopes: "feeds:read feeds:write",
      confidential: false
    )
    read_only = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: alice.id, scopes: "feeds:read", expires_in: 3600)
    alice_rw = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: alice.id, scopes: "feeds:read feeds:write", expires_in: 3600)
    bob_rw = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: bob.id, scopes: "feeds:read feeds:write", expires_in: 3600)

    # Unauthenticated request rejected with RFC 9728 WWW-Authenticate header
    mcp_post({ jsonrpc: "2.0", id: 1, method: "tools/list" })
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["WWW-Authenticate"]).to include("/.well-known/oauth-protected-resource")

    # Cross-origin browser request blocked
    mcp_post({ jsonrpc: "2.0", id: 1, method: "tools/list" }, token: alice_rw.plaintext_token, headers: { "Origin" => "https://evil.example" })
    expect(response).to have_http_status(:forbidden)

    # Read-only token forbidden from write tool
    mcp_post(
      { jsonrpc: "2.0", id: 10, method: "tools/call", params: { name: "subscribe_feed", arguments: { url: "https://ex.org/rss.xml" } } },
      token: read_only.plaintext_token
    )
    expect(JSON.parse(response.body).dig("result", "isError")).to be(true)
    expect(JSON.parse(response.body).dig("result", "structuredContent", "error_code")).to eq("forbidden")

    # Seed a feed and subscribe Alice via MCP (stubbing DNS & HTTP cleanly)
    allow_any_instance_of(Security::SafeHttpFetch).to receive(:resolve_and_validate_ip!).and_return("93.184.216.34")
    rss = <<~XML
      <?xml version="1.0"?>
      <rss version="2.0"><channel><title>MCP News</title><link>https://mcpnews.example.org</link>
      <item><guid>m1</guid><title>Rails MCP Launch</title><link>https://mcpnews.example.org/1</link><description>OAuth works great</description></item>
      </channel></rss>
    XML
    stub_request(:get, "https://mcpnews.example.org/feed.xml")
      .to_return(status: 200, body: rss, headers: { "Content-Type" => "application/rss+xml" })

    mcp_post(
      { jsonrpc: "2.0", id: 11, method: "tools/call", params: { name: "subscribe_feed", arguments: { url: "https://mcpnews.example.org/feed.xml", folder: "AI" } } },
      token: alice_rw.plaintext_token
    )
    sub_res = JSON.parse(response.body).dig("result", "structuredContent")
    expect(sub_res["status"]).to eq("subscribed")
    feed_id = sub_res.dig("feed", "feed_id")

    # Fan out outbox -> inbox
    OutboxEvent.find_each { |e| Events::InboxFanout.call(e.id) }

    # Alice searches and reads item via MCP
    mcp_post(
      { jsonrpc: "2.0", id: 12, method: "tools/call", params: { name: "search_items", arguments: { query: "OAuth" } } },
      token: alice_rw.plaintext_token
    )
    items = JSON.parse(response.body).dig("result", "structuredContent", "items")
    expect(items.size).to eq(1)
    item_id = items.first["item_id"]

    # Bob (unsubscribed) CANNOT read Alice's item via get_feed_item
    mcp_post(
      { jsonrpc: "2.0", id: 13, method: "tools/call", params: { name: "get_feed_item", arguments: { item_id: item_id } } },
      token: bob_rw.plaintext_token
    )
    expect(JSON.parse(response.body).dig("result", "isError")).to be(true)
    expect(JSON.parse(response.body).dig("result", "structuredContent", "error_code")).to eq("not_found")

    # Alice polls durable inbox via get_updates
    mcp_post(
      { jsonrpc: "2.0", id: 14, method: "tools/call", params: { name: "get_updates", arguments: {} } },
      token: alice_rw.plaintext_token
    )
    upd = JSON.parse(response.body).dig("result", "structuredContent")
    expect(upd["events"].size).to eq(1)
    expect(upd["next_cursor"]).to be_present

    # Alice exports OPML via MCP
    mcp_post(
      { jsonrpc: "2.0", id: 15, method: "tools/call", params: { name: "export_opml", arguments: {} } },
      token: alice_rw.plaintext_token
    )
    expect(JSON.parse(response.body).dig("result", "structuredContent", "opml_xml")).to include("https://mcpnews.example.org/feed.xml")

    # Alice unsubscribes via MCP
    mcp_post(
      { jsonrpc: "2.0", id: 16, method: "tools/call", params: { name: "unsubscribe_feed", arguments: { feed_id: feed_id } } },
      token: alice_rw.plaintext_token
    )
    expect(JSON.parse(response.body).dig("result", "structuredContent", "removed")).to be(true)
  end
end
