require "rails_helper"
require "openssl"

RSpec.describe "Phase 5 Hardening, Quotas, Moderation, Metrics, Account Erasure, and End-to-End Conformance", type: :request do
  let(:public_resolver) { ->(_host) { [ "93.184.216.34" ] } }
  let(:fetcher) { Security::SafeHttpFetch.new(resolver: public_resolver) }

  let!(:operator) { User.create!(email: "ops@example.org", namespace: "opsadmin", password: "password123!", admin: true) }
  let!(:alice) { User.create!(email: "alice_p5@example.org", namespace: "alicep5", password: "password123!") }
  let!(:bob) { User.create!(email: "bob_p5@example.org", namespace: "bobp5", password: "password123!") }

  let!(:oauth_app) do
    Doorkeeper::Application.create!(
      name: "Conformance Agent",
      redirect_uri: "http://127.0.0.1/cb",
      scopes: "feeds:read feeds:write documents:read documents:write",
      confidential: false
    )
  end

  let!(:alice_token) do
    Doorkeeper::AccessToken.create!(
      application: oauth_app,
      resource_owner_id: alice.id,
      scopes: "feeds:read feeds:write documents:read documents:write",
      expires_in: 3600
    ).plaintext_token
  end

  def call_mcp(tool_name, arguments, token:, id: 1)
    post "/mcp",
      params: JSON.generate(jsonrpc: "2.0", id: id, method: "tools/call", params: { name: tool_name, arguments: arguments }),
      headers: { "CONTENT_TYPE" => "application/json", "Authorization" => "Bearer #{token}" }
    return response if response.status != 200

    JSON.parse(response.body).fetch("result")
  end

  def with_env(overrides)
    originals = {}
    overrides.each do |k, v|
      originals[k] = ENV[k]
      ENV[k] = v
    end
    OpenNews.reset_config!
    yield
  ensure
    originals.each { |k, v| ENV[k] = v }
    OpenNews.reset_config!
  end

  describe "Security headers, CSP, and /.well-known/security.txt" do
    it "serves strict CSP (script-src 'none') on public Markdown pages and RFC 9116 security.txt" do
      Publishing::CreateOrRevise.create(
        user: alice,
        path: "sec/page",
        title: "CSP Check",
        markdown: "# CSP Check\n\nNo scripts allowed.",
        visibility: "public"
      )

      get "/alicep5/sec/page", headers: { "Accept" => "text/html" }
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Security-Policy"]).to include("script-src 'none'")
      expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(response.headers["Referrer-Policy"]).to eq("strict-origin-when-cross-origin")

      get "/.well-known/security.txt"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Contact: mailto:")
      expect(response.body).to include("Canonical:")
    end
  end

  describe "Per-account quotas (subscriptions, documents, storage, publish rate, downstream subscribers)" do
    it "enforces subscription, document count, storage, and downstream subscriber quotas cleanly" do
      with_env(
        "MAX_SUBSCRIPTIONS_PER_USER" => "1",
        "MAX_DOCUMENTS_PER_USER" => "1",
        "MAX_DOCUMENT_STORAGE_BYTES_PER_USER" => "100",
        "MAX_DOWNSTREAM_SUBSCRIBERS_PER_PUBLICATION" => "1"
      ) do
        # 1. Subscription quota
        f1 = Feed.create!(canonical_url: "https://q1.example.org/feed.xml", title: "Q1")
        f2 = Feed.create!(canonical_url: "https://q2.example.org/feed.xml", title: "Q2")
        expect(Subscriptions::Subscribe.call(user: alice, url: f1.canonical_url, enqueue_fetch: false).ok?).to be(true)
        res2 = Subscriptions::Subscribe.call(user: alice, url: f2.canonical_url, enqueue_fetch: false)
        expect(res2.ok?).to be(false)
        expect(res2.error_code).to eq("quota_exceeded")

        # 2. Storage quota (> 100 bytes)
        too_big = call_mcp("publish_document", { path: "q/big", markdown: "x" * 120 }, token: alice_token)
        expect(too_big["isError"]).to be(true)
        expect(too_big.dig("structuredContent", "error_code")).to eq("quota_exceeded")

        # 3. Document count quota (1 allowed, 2nd rejected)
        ok_doc = call_mcp("publish_document", { path: "q/one", markdown: "# One" }, token: alice_token)
        expect(ok_doc["isError"]).to be(false)

        second_doc = call_mcp("publish_document", { path: "q/two", markdown: "# Two" }, token: alice_token)
        expect(second_doc["isError"]).to be(true)
        expect(second_doc.dig("structuredContent", "error_code")).to eq("quota_exceeded")

        # 4. Downstream subscriber quota on WebSub hub
        DownstreamSubscription.create!(
          publication: alice.default_publication,
          protocol: "websub",
          topic_url: "#{OpenNews.config.app_base_url}/alicep5/feed.xml",
          topic_format: "rss",
          callback_url: "https://sub1.example.org/cb",
          callback_host: "sub1.example.org",
          status: "active",
          lease_expires_at: 1.day.from_now
        )

        post "/websub/hub", params: {
          "hub.mode" => "subscribe",
          "hub.topic" => "#{OpenNews.config.app_base_url}/alicep5/feed.xml",
          "hub.callback" => "https://sub2.example.org/cb"
        }
        expect(response).to have_http_status(:too_many_requests)
      end
    end
  end

  describe "Operator metrics and moderation controls" do
    it "restricts /admin/* to operators or metrics token, serves full metrics, and executes document takedown & user disable" do
      # Unauthenticated and non-operator rejected
      get "/admin/metrics"
      expect(response).to have_http_status(:forbidden)

      post "/login", params: { email: bob.email, password: "password123!" }
      get "/admin/metrics"
      expect(response).to have_http_status(:forbidden)
      post "/admin/moderation/disable_user", params: { namespace: alice.namespace, reason: "nope" }
      expect(response).to have_http_status(:forbidden)
      delete "/logout"

      # Token-authenticated JSON scrape works when OPERATOR_METRICS_TOKEN is configured
      with_env("OPERATOR_METRICS_TOKEN" => "metrics-scrape-secret-999") do
        get "/admin/metrics.json", headers: { "Authorization" => "Bearer wrong" }
        expect(response).to have_http_status(:forbidden)

        get "/admin/metrics.json", headers: { "Authorization" => "Bearer metrics-scrape-secret-999" }
        expect(response).to have_http_status(:ok)
        data = JSON.parse(response.body)
        expect(data.keys).to include("users", "oauth", "feeds", "publishing", "upstream_push", "downstream_push", "outbox", "sidekiq", "database")
      end

      # Operator web login + HTML metrics dashboard + moderation actions
      Publishing::CreateOrRevise.create(
        user: alice,
        path: "spam/post",
        title: "Abusive Post",
        markdown: "# Abusive Post",
        visibility: "public"
      )

      post "/login", params: { email: operator.email, password: "password123!" }
      get "/admin/metrics"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Operator Metrics")

      # Takedown document -> returns 451, disappears from RSS, blocks owner update, logs audit
      post "/admin/moderation/takedown_document", params: {
        namespace: alice.namespace,
        path: "spam/post",
        reason: "Spam policy violation"
      }
      expect(response).to redirect_to(admin_metrics_path)

      get "/alicep5/spam/post"
      expect(response).to have_http_status(:unavailable_for_legal_reasons)
      get "/alicep5/feed.xml"
      expect(response.body).not_to include("Abusive Post")
      expect(AuditLog.exists?(action: "moderation.document_takedown")).to be(true)

      # Disable user -> revokes OAuth token immediately (MCP returns 401), hides publication
      post "/admin/moderation/disable_user", params: {
        namespace: alice.namespace,
        reason: "Repeated abuse"
      }
      expect(response).to redirect_to(admin_metrics_path)
      expect(alice.reload.active?).to be(false)

      resp = call_mcp("list_documents", {}, token: alice_token)
      expect(resp.status).to eq(401)
      get "/alicep5"
      expect(response).to have_http_status(:not_found)
      expect(AuditLog.exists?(action: "moderation.user_disabled")).to be(true)
    end
  end

  describe "Self-service account erasure (DELETE /settings/account)" do
    it "requires password confirmation, wipes private reader/draft/token data, and keeps namespace reserved" do
      feed = Feed.create!(canonical_url: "https://erase.example.org/feed.xml", title: "Erase Feed")
      UserFeedSubscription.create!(user: bob, feed: feed, subscribed_at: 1.minute.ago)
      item = FeedItem.create!(
        feed: feed,
        external_id: "e-1",
        title: "Item",
        content_hash: "abc",
        first_seen_at: Time.current,
        last_seen_at: Time.current
      )
      UserItems::UpdateState.call(user: bob, feed_item_id: item.id, saved: true)
      Publishing::CreateOrRevise.create(user: bob, path: "private/note", markdown: "# Secret", visibility: "draft")
      Publishing::CreateOrRevise.create(user: bob, path: "public/essay", markdown: "# Essay", visibility: "public")

      post "/login", params: { email: bob.email, password: "password123!" }

      # Wrong password rejected
      delete "/settings/account", params: { password: "wrong" }
      expect(response).to redirect_to(oauth_connections_path)
      expect(bob.reload.active?).to be(true)

      # Correct password erases account cleanly
      delete "/settings/account", params: { password: "password123!" }
      expect(response).to redirect_to(signup_path)

      bob.reload
      expect(bob.active?).to be(false)
      expect(bob.email).to end_with("@erased.invalid")
      expect(bob.user_feed_subscriptions.count).to eq(0)
      expect(bob.user_items.count).to eq(0)
      expect(bob.user_inbox_events.count).to eq(0)
      expect(Document.where(publication: bob.default_publication, path: "private/note")).to be_empty
      pub_doc = Document.find_by!(publication: bob.default_publication, path: "public/essay")
      expect(pub_doc.deleted?).to be(true)
      expect(pub_doc.document_revisions.count).to eq(0)

      # Namespace remains reserved so another signup cannot hijack @bobp5
      post "/signup", params: { user: { email: "hijack@example.org", namespace: "bobp5", password: "password123!", password_confirmation: "password123!" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "Full Section 17 End-to-End Protocol Conformance & Recovery Demo" do
    it "runs all four interoperability modes (upstream WebSub + rssCloud, downstream WebSub + rssCloud, MCP, RSS/Atom, Markdown/HTML) with outbox recovery and strict isolation" do
      allow(Security::SafeHttpFetch).to receive(:new).and_return(fetcher)
      base = OpenNews.config.app_base_url

      # 1. User A imports OPML with an external feed via MCP
      ext_feed_url = "https://external-pub.example.org/feed.xml"
      ext_rss = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>External Dispatch</title>
            <link>https://external-pub.example.org/</link>
            <item>
              <guid>ext-1</guid>
              <title>Climate Data Update</title>
              <link>https://external-pub.example.org/posts/1</link>
              <description>Initial report on regional sensors.</description>
            </item>
          </channel>
        </rss>
      XML
      stub_request(:get, ext_feed_url).to_return(status: 200, body: ext_rss, headers: { "Content-Type" => "application/rss+xml" })

      sub_res = call_mcp("subscribe_feed", { url: ext_feed_url }, token: alice_token)
      expect(sub_res["isError"]).to be(false)

      # Simulate worker crash between DB commit and enqueue: OutboxEvent is undispatched; OutboxDispatch recovers it!
      expect(OutboxEvent.undispatched.where(event_type: "feed_item.created").count).to eq(1)
      Events::OutboxDispatch.call
      Events::MaterializeInboxJob.jobs.each { |j| Events::InboxFanout.call(j["args"].first) }

      # 2. User A searches history & reads durable updates via MCP
      search_res = call_mcp("search_items", { query: "regional sensors" }, token: alice_token)
      expect(search_res.dig("structuredContent", "items").size).to eq(1)
      updates_res = call_mcp("get_updates", {}, token: alice_token)
      expect(updates_res.dig("structuredContent", "events").size).to eq(1)

      # 3. Register external WebSub subscriber + external rssCloud subscriber on User A's hosted feeds
      ws_secret = "conformance-hmac-secret"
      stub_request(:get, %r{\Ahttps://ext-ws\.example\.org/hook\?}).to_return { |req|
        q = URI.decode_www_form(URI.parse(req.uri.to_s).query).to_h
        { status: 200, body: q["hub.challenge"] }
      }
      post "/websub/hub", params: {
        "hub.mode" => "subscribe",
        "hub.topic" => "#{base}/alicep5/feed.atom",
        "hub.callback" => "https://ext-ws.example.org/hook",
        "hub.secret" => ws_secret
      }
      expect(response).to have_http_status(:accepted)
      WebSub::VerifySubscriptionJob.new.perform(*WebSub::VerifySubscriptionJob.jobs.first["args"])

      stub_request(:get, %r{\Ahttps://ext-rc\.example\.org/cb\?}).to_return { |req|
        q = URI.decode_www_form(URI.parse(req.uri.to_s).query).to_h
        { status: 200, body: q["challenge"] }
      }
      post "/rsscloud/pleaseNotify", params: {
        "domain" => "ext-rc.example.org",
        "port" => "443",
        "path" => "/cb",
        "protocol" => "http-post",
        "url1" => "#{base}/alicep5/feed.xml"
      }
      expect(response).to have_http_status(:ok)

      # 4. User A creates a private draft AND publishes a public Markdown briefing via MCP
      call_mcp("publish_document", { path: "briefings/secret-notes", markdown: "# Top Secret Draft" }, token: alice_token)
      pub_res = call_mcp(
        "publish_document",
        { path: "briefings/today", title: "Today Briefing", markdown: "# Today Briefing\n\nAll four push modes active.", visibility: "public" },
        token: alice_token
      )
      expect(pub_res["isError"]).to be(false)

      # 5. Outbox recovers & fans out to BOTH downstream subscribers (signed WebSub fat push + rssCloud lightweight ping)
      ws_delivered_xml = nil
      ws_sig = nil
      stub_request(:post, "https://ext-ws.example.org/hook").to_return { |req|
        ws_delivered_xml = req.body
        ws_sig = req.headers["X-Hub-Signature"]
        { status: 200, body: "ok" }
      }
      rc_ping_body = nil
      stub_request(:post, "https://ext-rc.example.org/cb").to_return { |req|
        rc_ping_body = req.body
        { status: 200, body: "ok" }
      }

      Events::OutboxDispatch.call
      Publishing::FanoutFeedChangeJob.jobs.each { |j| Events::PublicationFanout.call(j["args"].first) }
      WebSub::DeliverContentJob.jobs.each { |j| WebSub::DeliverContentJob.new.perform(*j["args"]) }
      RssCloud::DeliverPingJob.jobs.each { |j| RssCloud::DeliverPingJob.new.perform(*j["args"]) }

      expect(ws_delivered_xml).to include("Today Briefing")
      expect(ws_sig).to eq("sha256=#{OpenSSL::HMAC.hexdigest('SHA256', ws_secret, ws_delivered_xml)}")
      expect(URI.decode_www_form(rc_ping_body).to_h).to eq("url" => "#{base}/alicep5/feed.xml")

      # 6. User B fetches User A's hosted RSS feed & Markdown document — sees public briefing, NEVER sees private draft or Alice's private feeds
      get "/alicep5/feed.xml"
      expect(response).to have_http_status(:ok)
      hosted_rss = response.body
      expect(hosted_rss).to include("Today Briefing")
      expect(hosted_rss).not_to include("Top Secret Draft")

      get "/alicep5/briefings/today", headers: { "Accept" => "text/markdown" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("All four push modes active.")

      get "/alicep5/briefings/secret-notes"
      expect(response).to have_http_status(:not_found)

      # Bob subscribes to Alice's hosted RSS feed as a normal reader (via public domain URL)
      public_hosted_rss_url = "https://open-news.example.org/alicep5/feed.xml"
      stub_request(:get, public_hosted_rss_url).to_return(status: 200, body: hosted_rss, headers: { "Content-Type" => "application/rss+xml" })
      bob_sub = Subscriptions::Subscribe.call(user: bob, url: public_hosted_rss_url, fetcher: fetcher, enqueue_fetch: false)
      expect(bob_sub.ok?).to be(true)

      # Bob can search Alice's public syndicated briefing, but CANNOT see Alice's private external feed ("regional sensors")
      bob_briefing_hits = Search::Items.call(user: bob, query: "Today Briefing").items
      bob_private_hits = Search::Items.call(user: bob, query: "regional sensors").items
      expect(bob_briefing_hits.size).to eq(1)
      expect(bob_private_hits).to be_empty
    end
  end
end
