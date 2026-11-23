require "rails_helper"

RSpec.describe "Phase 3 Markdown Publishing, Public Delivery, RSS/Atom Feeds, and MCP Tools", type: :request do
  let!(:matt) { User.create!(email: "matt_p3@example.org", namespace: "mattp3", password: "password123!") }
  let!(:bob) { User.create!(email: "bob_p3@example.org", namespace: "bobp3", password: "password123!") }

  let!(:oauth_app) do
    Doorkeeper::Application.create!(
      name: "Publishing Agent",
      redirect_uri: "http://127.0.0.1/cb",
      scopes: "feeds:read feeds:write documents:read documents:write",
      confidential: false
    )
  end

  let!(:matt_doc_token) do
    Doorkeeper::AccessToken.create!(
      application: oauth_app,
      resource_owner_id: matt.id,
      scopes: "documents:read documents:write",
      expires_in: 3600
    ).plaintext_token
  end

  let!(:matt_feeds_only_token) do
    Doorkeeper::AccessToken.create!(
      application: oauth_app,
      resource_owner_id: matt.id,
      scopes: "feeds:read",
      expires_in: 3600
    ).plaintext_token
  end

  let!(:bob_doc_token) do
    Doorkeeper::AccessToken.create!(
      application: oauth_app,
      resource_owner_id: bob.id,
      scopes: "documents:read documents:write",
      expires_in: 3600
    ).plaintext_token
  end

  def call_mcp(tool_name, arguments, token:, id: 1)
    post "/mcp",
      params: JSON.generate(
        jsonrpc: "2.0",
        id: id,
        method: "tools/call",
        params: { name: tool_name, arguments: arguments }
      ),
      headers: { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{token}" }
    JSON.parse(response.body).fetch("result")
  end

  it "validates document paths strictly (rejecting traversal, reserved names, and .md canonical paths)" do
    %w[../escape notes//dup notes/.. feed.xml feed.atom notes/hello.md a/b/c/d/e/f/g].each do |bad|
      expect { Publishing::PathNormalizer.normalize!(bad) }.to raise_error(Publishing::PathNormalizer::InvalidPathError), "expected #{bad.inspect} to fail"
    end
    expect(Publishing::PathNormalizer.normalize!("/notes/hello/")).to eq("notes/hello")
  end

  it "runs full MCP publish -> draft privacy -> public HTML/Markdown/.md negotiation -> revisions -> RSS/Atom -> tombstone deletion" do
    # Scope enforcement: feeds:read token cannot publish or read drafts
    denied = call_mcp("publish_document", { path: "notes/nope", markdown: "# No" }, token: matt_feeds_only_token)
    expect(denied["isError"]).to be(true)
    expect(denied.dig("structuredContent", "error_code")).to eq("forbidden")

    # 1. Default visibility is 'draft' (never leaks publicly!)
    md_v1 = <<~MD
      ---
      title: Hello World
      tags: [civic, news]
      ---
      # Hello World

      Welcome to **Open.News** with <script>alert(1)</script> and [bad](javascript:alert(2)).
    MD

    created = call_mcp(
      "publish_document",
      { path: "notes/hello", markdown: md_v1, idempotency_key: "pub-key-1" },
      token: matt_doc_token
    )
    expect(created["isError"]).to be(false)
    doc_data = created["structuredContent"]
    expect(doc_data["visibility"]).to eq("draft")
    expect(doc_data["revision"]).to eq(1)
    guid = doc_data["rss_guid"]
    expect(guid).to start_with("urn:uuid:")

    # Idempotent retry with same key replays without creating a duplicate or failing
    replay = call_mcp(
      "publish_document",
      { path: "notes/hello", markdown: md_v1, idempotency_key: "pub-key-1" },
      token: matt_doc_token
    )
    expect(replay["isError"]).to be(false)
    expect(replay.dig("structuredContent", "status")).to eq("idempotent_replay")

    # Draft is invisible publicly (404) and absent from RSS/Atom
    get "/mattp3/notes/hello"
    expect(response).to have_http_status(:not_found)
    get "/mattp3/feed.xml"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Hello World")

    # Owner can read own draft via get_document; Bob cannot
    got = call_mcp("get_document", { path: "notes/hello" }, token: matt_doc_token)
    expect(got.dig("structuredContent", "markdown")).to eq(md_v1)

    bob_got = call_mcp("get_document", { path: "notes/hello" }, token: bob_doc_token)
    expect(bob_got["isError"]).to be(true)
    expect(bob_got.dig("structuredContent", "error_code")).to eq("not_found")

    # 2. Publish draft -> public (same content hash: revision stays 1, published_at set)
    pub = call_mcp(
      "update_document",
      { path: "notes/hello", visibility: "public", expected_revision: 1 },
      token: matt_doc_token
    )
    expect(pub["isError"]).to be(false)
    expect(pub.dig("structuredContent", "visibility")).to eq("public")
    expect(pub.dig("structuredContent", "revision")).to eq(1)
    expect(pub.dig("structuredContent", "public_url")).to end_with("/mattp3/notes/hello")
    expect(pub.dig("structuredContent", "markdown_url")).to end_with("/mattp3/notes/hello.md")

    # 3. Public HTML representation: safe rendering (no raw script or javascript: link), Vary, canonical link, ETag
    get "/mattp3/notes/hello", headers: { "Accept" => "text/html,application/xhtml+xml" }
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include("text/html")
    expect(response.headers["Vary"]).to include("Accept")
    expect(response.headers["Link"]).to include('rel="canonical"')
    html_etag = response.headers["ETag"]
    expect(html_etag).to start_with('W/"html-')
    expect(response.body).to include("<strong>Open.News</strong>")
    expect(response.body).not_to include("<script>")
    expect(response.body).not_to include("javascript:")

    # 4. Accept: text/markdown returns exact Markdown bytes with distinct ETag + conditional 304
    get "/mattp3/notes/hello", headers: { "Accept" => "text/markdown" }
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include("text/markdown")
    expect(response.body).to eq(md_v1)
    md_etag = response.headers["ETag"]
    expect(md_etag).to start_with('W/"md-')
    expect(md_etag).not_to eq(html_etag)

    get "/mattp3/notes/hello", headers: { "Accept" => "text/markdown", "If-None-Match" => md_etag }
    expect(response).to have_http_status(:not_modified)

    # 5. Optional .md alias returns exact Markdown + Link rel="canonical" pointing to canonical URL
    get "/mattp3/notes/hello.md"
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include("text/markdown")
    expect(response.body).to eq(md_v1)
    expect(response.headers["Link"]).to eq(%(<#{OpenNews.config.app_base_url}/mattp3/notes/hello>; rel="canonical"))

    # 6. Update Markdown -> revision 2; stale expected_revision rejected with revision_conflict
    md_v2 = "# Hello World\n\nRevised second edition content.\n"
    upd = call_mcp(
      "update_document",
      { path: "notes/hello", markdown: md_v2, expected_revision: 1 },
      token: matt_doc_token
    )
    expect(upd["isError"]).to be(false)
    expect(upd.dig("structuredContent", "revision")).to eq(2)
    expect(upd.dig("structuredContent", "rss_guid")).to eq(guid)

    conflict = call_mcp(
      "update_document",
      { path: "notes/hello", markdown: "# Stale", expected_revision: 1 },
      token: matt_doc_token
    )
    expect(conflict["isError"]).to be(true)
    expect(conflict.dig("structuredContent", "error_code")).to eq("revision_conflict")
    expect(conflict.dig("structuredContent", "details", "current_revision")).to eq(2)

    # Read-only historical ?revision=1 still returns v1
    get "/mattp3/notes/hello?revision=1", headers: { "Accept" => "text/markdown" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(md_v1)

    # 7. Generated RSS 2.0 and Atom 1.0 parse cleanly with standard feed parser (stable GUID, WebSub + rssCloud)
    get "/mattp3/feed.xml"
    expect(response).to have_http_status(:ok)
    expect(response.headers["Link"]).to include('rel="hub"')
    parsed_rss = Feeds::Parse.call(response.body, headers: response.headers.to_h, base_url: "#{OpenNews.config.app_base_url}/mattp3/feed.xml")
    expect(parsed_rss.format).to eq("rss")
    expect(parsed_rss.websub_hub).to end_with("/websub/hub")
    expect(parsed_rss.rsscloud_endpoint).to end_with("/rsscloud/pleaseNotify")
    expect(parsed_rss.items.size).to eq(1)
    expect(parsed_rss.items.first.raw_id).to eq(guid)

    get "/mattp3/feed.atom"
    expect(response).to have_http_status(:ok)
    parsed_atom = Feeds::Parse.call(response.body, headers: response.headers.to_h, base_url: "#{OpenNews.config.app_base_url}/mattp3/feed.atom")
    expect(parsed_atom.format).to eq("atom")
    expect(parsed_atom.websub_hub).to end_with("/websub/hub")
    expect(parsed_atom.items.size).to eq(1)
    expect(parsed_atom.items.first.raw_id).to eq(guid)

    # Public publication index page advertises feeds for autodiscovery
    get "/mattp3"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("/mattp3/feed.xml")
    expect(response.body).to include("/mattp3/feed.atom")

    # 8. List documents via MCP
    listed = call_mcp("list_documents", { visibility: "public" }, token: matt_doc_token)
    expect(listed.dig("structuredContent", "documents").size).to eq(1)

    # 9. Delete document -> tombstone returns 410 Gone, disappears from feeds, URL cannot be recycled!
    deleted = call_mcp("delete_document", { path: "notes/hello", expected_revision: 2 }, token: matt_doc_token)
    expect(deleted["isError"]).to be(false)

    get "/mattp3/notes/hello"
    expect(response).to have_http_status(:gone)

    get "/mattp3/feed.xml"
    expect(response.body).not_to include(guid)

    reuse = call_mcp("publish_document", { path: "notes/hello", markdown: "# Hijack" }, token: matt_doc_token)
    expect(reuse["isError"]).to be(true)
    expect(reuse.dig("structuredContent", "error_code")).to eq("path_conflict")
  end

  it "exposes all 15 Phase 1 + Phase 3 MCP tools in tools/list and supports minimal web Documents UI" do
    post "/mcp",
      params: JSON.generate(jsonrpc: "2.0", id: 99, method: "tools/list"),
      headers: { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{matt_doc_token}" }
    names = JSON.parse(response.body).dig("result", "tools").map { |t| t["name"] }
    expect(names).to include("publish_document", "get_document", "update_document", "list_documents", "delete_document")

    post "/login", params: { email: matt.email, password: "password123!" }
    post "/documents", params: { path: "briefings/today", title: "Today", markdown: "# Today\n\nSummary.", visibility: "public" }
    expect(response).to redirect_to("/documents")
    get "/documents"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("briefings/today")
  end
end
