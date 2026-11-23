require "rails_helper"
require "openssl"

RSpec.describe "Phase 2 WebSub Subscriber (Upstream Push)", type: :request do
  let(:public_resolver) { ->(_host) { [ "93.184.216.34" ] } }
  let(:fetcher) { Security::SafeHttpFetch.new(resolver: public_resolver) }

  let!(:alice) { User.create!(email: "ws_alice@example.org", namespace: "ws_alice", password: "password123!") }
  let!(:bob) { User.create!(email: "ws_bob@example.org", namespace: "ws_bob", password: "password123!") }

  let!(:feed) do
    Feed.create!(
      canonical_url: "https://blog.example.org/feed.xml",
      title: "Example Blog",
      discovered_websub_hub: "https://hub.example.org/",
      discovered_websub_topic: "https://blog.example.org/feed.xml"
    )
  end

  let(:pushed_rss) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Example Blog</title>
          <link>https://blog.example.org/</link>
          <item>
            <guid>ws-item-1</guid>
            <title>Live WebSub Push Story</title>
            <link>https://blog.example.org/posts/ws-1</link>
            <pubDate>Mon, 23 Nov 2026 14:00:00 GMT</pubDate>
            <description>Delivered straight from the WebSub hub without refetching.</description>
          </item>
        </channel>
      </rss>
    XML
  end

  before do
    UserFeedSubscription.create!(user: alice, feed: feed, subscribed_at: 2.minutes.ago)
    UserFeedSubscription.create!(user: bob, feed: feed, subscribed_at: 2.minutes.ago)
  end

  it "subscribes once per canonical feed, encrypts secrets at rest, verifies intent, and ingests signed full feed without refetch" do
    hub_stub = stub_request(:post, "https://hub.example.org/")
      .with { |req|
        params = URI.decode_www_form(req.body).to_h
        params["hub.mode"] == "subscribe" &&
          params["hub.topic"] == "https://blog.example.org/feed.xml" &&
          params["hub.callback"].include?("/callbacks/websub/") &&
          params["hub.secret"].present? &&
          params["hub.secret"].bytesize < 200
      }
      .to_return(status: 202, body: "")

    # Reconciling twice for two subscribers creates ONLY ONE shared upstream registration
    expect(Push::Reconciler.reconcile_feed(feed, fetcher: fetcher)).to eq(:websub)
    expect(Push::Reconciler.reconcile_feed(feed, fetcher: fetcher)).to eq(:websub)
    expect(hub_stub).to have_been_requested.once
    expect(UpstreamPushSubscription.count).to eq(1)

    sub = UpstreamPushSubscription.first
    expect(sub.status).to eq("pending")

    # Verify secret and callback_token are encrypted at rest in raw DB column
    raw_secret_col = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([ "SELECT secret FROM upstream_push_subscriptions WHERE id = ?", sub.id ])
    )
    expect(raw_secret_col).not_to eq(sub.secret)
    expect(raw_secret_col).to include('"p":')

    # Mismatched topic challenge is rejected (404)
    get "/callbacks/websub/#{sub.callback_token}", params: {
      "hub.mode" => "subscribe",
      "hub.topic" => "https://other.example.org/feed.xml",
      "hub.challenge" => "chal-bad"
    }
    expect(response).to have_http_status(:not_found)
    expect(sub.reload.status).to eq("pending")

    # Valid Verification of Intent activates subscription and echoes exact challenge
    get "/callbacks/websub/#{sub.callback_token}", params: {
      "hub.mode" => "subscribe",
      "hub.topic" => "https://blog.example.org/feed.xml",
      "hub.challenge" => "challenge-token-12345",
      "hub.lease_seconds" => "86400"
    }
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("challenge-token-12345")
    sub.reload
    expect(sub.status).to eq("active")
    expect(sub.lease_seconds).to eq(86_400)
    expect(sub.lease_expires_at).to be_present
    expect(sub.next_renew_at).to be < sub.lease_expires_at

    # Unsigned push is rejected (403) and NEVER ingested
    post "/callbacks/websub/#{sub.callback_token}",
      params: pushed_rss,
      headers: { "CONTENT_TYPE" => "application/rss+xml" }
    expect(response).to have_http_status(:forbidden)
    expect(StagedPushPayload.count).to eq(0)

    # Bad signature is rejected (403)
    post "/callbacks/websub/#{sub.callback_token}",
      params: pushed_rss,
      headers: {
        "CONTENT_TYPE" => "application/rss+xml",
        "X-Hub-Signature" => "sha256=#{"0" * 64}"
      }
    expect(response).to have_http_status(:forbidden)
    expect(StagedPushPayload.count).to eq(0)

    # Valid SHA-256 signed full feed push is durably staged and ingested WITHOUT any follow-up HTTP GET!
    sig = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", sub.secret, pushed_rss)}"
    post "/callbacks/websub/#{sub.callback_token}",
      params: pushed_rss,
      headers: {
        "CONTENT_TYPE" => "application/rss+xml",
        "X-Hub-Signature" => sig
      }
    expect(response).to have_http_status(:accepted)
    expect(StagedPushPayload.count).to eq(1)
    expect(Push::AcceptWebSubPayloadJob.jobs.size).to eq(1)

    staged_id = Push::AcceptWebSubPayloadJob.jobs.first["args"].first
    expect(WebSub::Subscriber.process_staged_payload(staged_id)).to eq(:ok)

    # Confirm zero outbound GET requests were made to blog.example.org (direct fat-push ingestion!)
    expect(a_request(:get, "https://blog.example.org/feed.xml")).not_to have_been_made
    expect(FeedItem.where(feed: feed, external_id: "ws-item-1").count).to eq(1)
    expect(feed.reload.last_ingestion_method).to eq("websub")

    # Fanout reaches both Alice and Bob
    OutboxEvent.find_each { |e| Events::InboxFanout.call(e.id) }
    expect(UserInboxEvent.where(user: alice).count).to eq(1)
    expect(UserInboxEvent.where(user: bob).count).to eq(1)

    # Duplicate signed push delivery produces ZERO duplicate items or inbox events
    post "/callbacks/websub/#{sub.callback_token}",
      params: pushed_rss,
      headers: { "CONTENT_TYPE" => "application/rss+xml", "X-Hub-Signature" => sig }
    expect(response).to have_http_status(:accepted)
    dup_staged_id = Push::AcceptWebSubPayloadJob.jobs.last["args"].first
    WebSub::Subscriber.process_staged_payload(dup_staged_id)
    expect(FeedItem.where(feed: feed).count).to eq(1)
    expect(OutboxEvent.where(event_type: "feed_item.created").count).to eq(1)
  end

  it "rejects arbitrary JSON or malformed WebSub payloads safely and falls back to guarded fetch" do
    stub_request(:post, "https://hub.example.org/").to_return(status: 202)
    res = WebSub::Subscriber.subscribe(feed, fetcher: fetcher)
    sub = res.subscription
    sub.update!(status: "active")

    json_body = '{"topic":"https://blog.example.org/feed.xml","items":[{"title":"Fake"}]}'
    sig = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", sub.secret, json_body)}"

    post "/callbacks/websub/#{sub.callback_token}",
      params: json_body,
      headers: { "CONTENT_TYPE" => "application/json", "X-Hub-Signature" => sig }
    expect(response).to have_http_status(:accepted)

    staged_id = Push::AcceptWebSubPayloadJob.jobs.last["args"].first
    expect(WebSub::Subscriber.process_staged_payload(staged_id)).to eq(:fallback_fetch)
    expect(StagedPushPayload.find(staged_id).status).to eq("failed")
    expect(FeedItem.count).to eq(0)
    expect(Feeds::FetchJob.jobs.size).to eq(1)
  end

  it "renews due leases, handles hub denial, and unsubscribes when last user leaves" do
    sub_stub = stub_request(:post, "https://hub.example.org/").to_return(status: 202)
    sub = WebSub::Subscriber.subscribe(feed, fetcher: fetcher).subscription

    # Denial callback marks error cleanly
    get "/callbacks/websub/#{sub.callback_token}", params: {
      "hub.mode" => "denied",
      "hub.topic" => feed.canonical_url,
      "hub.reason" => "rate limited"
    }
    expect(response).to have_http_status(:ok)
    expect(sub.reload.status).to eq("error")
    expect(sub.last_error).to include("rate limited")

    # Simulate active subscription approaching renewal
    sub.update!(status: "active", lease_expires_at: 30.minutes.from_now, next_renew_at: 1.minute.ago)
    Push::Reconciler.renew_due!(fetcher: fetcher)
    expect(sub_stub).to have_been_requested.twice

    # Unsubscribe all users -> reconciler sends hub.mode=unsubscribe
    UserFeedSubscription.active.where(feed: feed).update_all(unsubscribed_at: Time.current)
    Push::Reconciler.reconcile_feed(feed, fetcher: fetcher)
    expect(sub.reload.status).to eq("unsubscribing")

    get "/callbacks/websub/#{sub.callback_token}", params: {
      "hub.mode" => "unsubscribe",
      "hub.topic" => feed.canonical_url,
      "hub.challenge" => "bye-123"
    }
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("bye-123")
    expect(sub.reload.status).to eq("unsubscribed")
  end
end
