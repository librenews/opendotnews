require "rails_helper"

RSpec.describe "Phase 1.1 Shared Content Architecture" do
  let(:public_resolver) { ->(_host) { [ "93.184.216.34" ] } }
  let(:fetcher) { Security::SafeHttpFetch.new(resolver: public_resolver) }

  let!(:alice) { User.create!(email: "alice11@example.org", namespace: "alice11", password: "password123!") }
  let!(:bob) { User.create!(email: "bob11@example.org", namespace: "bob11", password: "password123!") }
  let!(:carol) { User.create!(email: "carol11@example.org", namespace: "carol11", password: "password123!") }

  let(:rss_xml) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
        <channel>
          <title>Shared Journal</title>
          <link>https://journal.example.org/</link>
          <atom:link href="https://hub.example.org/" rel="hub"/>
          <cloud domain="rpc.rsscloud.io" port="80" path="/pleaseNotify" protocol="http-post"/>
          <item>
            <guid>art-1</guid>
            <title>Distributed Consensus Primer</title>
            <link>https://journal.example.org/consensus</link>
            <pubDate>Mon, 23 Nov 2026 09:00:00 GMT</pubDate>
            <description>Deep dive into Raft and Paxos algorithms.</description>
          </item>
          <item>
            <guid>art-2</guid>
            <title>Postgres Advisory Locks</title>
            <link>https://journal.example.org/locks</link>
            <pubDate>Mon, 23 Nov 2026 10:00:00 GMT</pubDate>
            <description>Safe concurrent feed ingestion in PostgreSQL.</description>
          </item>
        </channel>
      </rss>
    XML
  end

  it "creates UserItem lazily, isolates per-user read/saved/archived state, and enforces authorization" do
    feed = Feed.create!(canonical_url: "https://journal.example.org/feed.xml")
    UserFeedSubscription.create!(user: alice, feed: feed, subscribed_at: 1.minute.ago)
    UserFeedSubscription.create!(user: bob, feed: feed, subscribed_at: 1.minute.ago)

    parsed = Feeds::Parse.call(rss_xml, base_url: feed.canonical_url)
    Feeds::Ingest.call(feed: feed, parsed_feed: parsed, raw_body: rss_xml)

    # Ingesting items MUST NOT eagerly create UserItem rows.
    expect(UserItem.count).to eq(0)

    item1 = FeedItem.find_by!(feed: feed, external_id: "art-1")
    item2 = FeedItem.find_by!(feed: feed, external_id: "art-2")

    # Alice marks item1 read + saved, and archives item2.
    ui1 = UserItems::UpdateState.call(user: alice, feed_item_id: item1.id, read: true, saved: true)
    expect(ui1).to be_read
    expect(ui1).to be_saved
    UserItems::UpdateState.call(user: alice, feed_item_id: item2.id, archived: true)

    expect(UserItem.where(user: alice).count).to eq(2)
    expect(UserItem.where(user: bob).count).to eq(0)

    # Alice's filters reflect her private state; Bob still sees both items as unread & unsaved.
    expect(Feeds::ListItems.call(user: alice, unread_only: true).items.map(&:id)).to eq([ item2.id ])
    expect(Feeds::ListItems.call(user: alice, saved_only: true).items.map(&:id)).to eq([ item1.id ])
    expect(Feeds::ListItems.call(user: alice, exclude_archived: true).items.map(&:id)).to eq([ item1.id ])

    expect(Feeds::ListItems.call(user: bob, unread_only: true).items.map(&:id)).to contain_exactly(item1.id, item2.id)
    expect(Feeds::ListItems.call(user: bob, saved_only: true).items).to be_empty

    expect(Search::Items.call(user: alice, query: "Raft", saved_only: true).items.map(&:id)).to eq([ item1.id ])
    expect(Search::Items.call(user: bob, query: "Raft", saved_only: true).items).to be_empty

    # Unsubscribed user Carol is forbidden from mutating state on Alice/Bob's feed item.
    expect {
      UserItems::UpdateState.call(user: carol, feed_item_id: item1.id, saved: true)
    }.to raise_error(UserItems::UpdateState::ForbiddenError)
  end

  it "converges polling, simulated push delivery, and retries onto identical stored items and inbox events" do
    feed = Feed.create!(canonical_url: "https://journal.example.org/feed.xml")
    UserFeedSubscription.create!(user: alice, feed: feed, subscribed_at: 1.minute.ago)

    adapter = Sources::Adapters::FeedAdapter.new(fetcher: fetcher)
    payload = adapter.parse_payload(rss_xml, base_url: feed.canonical_url)

    # 1. Poll ingestion
    r1 = Feeds::Ingest.call(
      feed: feed,
      normalized_items: payload[:items],
      source_attributes: payload[:source_attributes],
      raw_body: rss_xml,
      ingestion_method: "poll",
      http_status: 200
    )
    expect(r1.created_count).to eq(2)

    # 2. Simulated WebSub push of the exact same payload
    r2 = Feeds::Ingest.call(
      feed: feed,
      normalized_items: payload[:items],
      source_attributes: payload[:source_attributes],
      raw_body: rss_xml,
      ingestion_method: "websub",
      http_status: 200
    )
    expect(r2.created_count).to eq(0)
    expect(r2.updated_count).to eq(0)
    expect(r2.unchanged_count).to eq(2)

    expect(FeedItem.where(feed: feed).count).to eq(2)
    expect(FeedItemRevision.count).to eq(2)
    expect(OutboxEvent.where(event_type: "feed_item.created").count).to eq(2)

    OutboxEvent.find_each { |ev| Events::InboxFanout.call(ev.id) }
    OutboxEvent.find_each { |ev| Events::InboxFanout.call(ev.id) }
    expect(UserInboxEvent.where(user: alice).count).to eq(2)
  end

  it "supports pluggable non-RSS source adapters via Sources::Registry without changing FeedItem or Feeds::Ingest" do
    custom_adapter_class = Class.new(Sources::Adapters::Base) do
      def self.source_type = "web"

      def fetch(source)
        item = Sources::NormalizedItem.new(
          external_id: "web:doc-99",
          external_url: "#{source.canonical_url}/doc-99",
          title: "Municipal Budget PDF Summary",
          summary_text: "FY2027 capital budget breakdown",
          content_text: "FY2027 capital budget breakdown for parks and transit",
          published_at: Time.current,
          content_hash: Digest::SHA256.hexdigest("web:doc-99:v1"),
          metadata: { "extractor" => "dom-selector-v1" }
        )
        Sources::FetchResult.new(
          status: :ok,
          items: [ item ],
          source_attributes: { title: "City Portal" },
          source_metadata: { "adapter_version" => 1 },
          etag: nil,
          last_modified: nil,
          raw_body: "html-snapshot",
          http_status: 200,
          duration_ms: 42,
          response: nil,
          error: nil,
          diagnostics: { "adapter" => "custom_web" }
        )
      end
    end

    Sources::Registry.register("web", custom_adapter_class)
    begin
      web_source = Feed.create!(canonical_url: "https://city.example.org/notices", source_type: "web")
      UserFeedSubscription.create!(user: alice, feed: web_source, subscribed_at: 1.minute.ago)

      res = Feeds::Fetch.call(web_source)
      expect(res.status).to eq(:ok)
      expect(web_source.reload.title).to eq("City Portal")
      expect(web_source.source_metadata["adapter_version"]).to eq(1)
      expect(web_source.last_diagnostics["adapter"]).to eq("custom_web")

      item = FeedItem.find_by!(feed: web_source, external_id: "web:doc-99")
      expect(item.metadata["extractor"]).to eq("dom-selector-v1")
      expect(Search::Items.call(user: alice, query: "capital budget").items.map(&:id)).to eq([ item.id ])
    ensure
      Sources::Registry.reset!
    end
  end

  it "tracks operational diagnostics across success, failure, and recovery without losing last_successful_fetch_at" do
    feed = Feed.create!(canonical_url: "https://ops.example.org/feed.xml")
    stub_request(:get, "https://ops.example.org/feed.xml")
      .to_return(status: 200, body: rss_xml, headers: { "Content-Type" => "application/rss+xml", "ETag" => '"ops1"' })

    res1 = Feeds::Fetch.call(feed, fetcher: fetcher)
    expect(res1.status).to eq(:ok)
    feed.reload
    first_success = feed.last_successful_fetch_at
    expect(first_success).to be_present
    expect(feed.last_http_status).to eq(200)
    expect(feed.last_fetch_duration_ms).to be >= 0
    expect(feed.last_ingestion_method).to eq("poll")
    expect(feed.last_diagnostics["websub_advertised"]).to be(true)
    expect(feed.last_diagnostics["rsscloud_advertised"]).to be(true)

    # Upstream 503 failure records last_error_at & http_status=503 while preserving last_successful_fetch_at
    stub_request(:get, "https://ops.example.org/feed.xml").to_return(status: 503, body: "unavailable")
    res2 = Feeds::Fetch.call(feed, fetcher: fetcher)
    expect(res2.status).to eq(:error)
    feed.reload
    expect(feed.last_http_status).to eq(503)
    expect(feed.last_error_at).to be_present
    expect(feed.fetch_failure_count).to eq(1)
    expect(feed.last_successful_fetch_at).to eq(first_success)

    # Recovery via 304 Not Modified clears error state and updates last_successful_fetch_at
    stub_request(:get, "https://ops.example.org/feed.xml").to_return(status: 304)
    res3 = Feeds::Fetch.call(feed, fetcher: fetcher)
    expect(res3.status).to eq(:not_modified)
    feed.reload
    expect(feed.fetch_failure_count).to eq(0)
    expect(feed.last_error).to be_nil
    expect(feed.last_http_status).to eq(304)
    expect(feed.last_successful_fetch_at).to be >= first_success
  end
end

RSpec.describe "Concurrent ingestion safety", type: :model do
  self.use_transactional_tests = false

  after do
    UserInboxEvent.delete_all
    OutboxEvent.delete_all
    FeedItemRevision.delete_all
    UserItem.delete_all
    FeedItem.delete_all
    UserFeedSubscription.delete_all
    FeedAlias.delete_all
    Feed.delete_all
  end

  it "handles concurrent multi-threaded ingestion of the same feed without uniqueness violations or duplicates" do
    feed = Feed.create!(canonical_url: "https://concurrent.example.org/feed.xml")
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel><title>Concurrent</title><link>https://concurrent.example.org</link>
      <item><guid>c-1</guid><title>Race Test</title><link>https://concurrent.example.org/1</link><description>Body</description></item>
      </channel></rss>
    XML
    parsed = Feeds::Parse.call(xml, base_url: feed.canonical_url)

    errors = Queue.new
    results = Queue.new

    threads = 5.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          results << Feeds::Ingest.call(feed: feed, parsed_feed: parsed, raw_body: xml)
        end
      rescue StandardError => e
        errors << e
      end
    end
    threads.each(&:join)

    expect(errors).to be_empty
    statuses = []
    statuses << results.pop until results.empty?
    expect(statuses.map(&:status)).to include(:ok)
    expect(statuses.all? { |r| %i[ok locked].include?(r.status) }).to be(true)

    expect(FeedItem.where(feed: feed).count).to eq(1)
    expect(FeedItemRevision.count).to eq(1)
    expect(OutboxEvent.where(event_type: "feed_item.created").count).to eq(1)
  end
end

RSpec.describe "Phase 1.1 Diagnostics & UserItem Web Endpoints", type: :request do
  let!(:alice) { User.create!(email: "ui11a@example.org", namespace: "ui11a", password: "password123!") }
  let!(:bob) { User.create!(email: "ui11b@example.org", namespace: "ui11b", password: "password123!") }

  it "authorizes feed diagnostics and private item state updates" do
    feed = Feed.create!(
      canonical_url: "https://diag.example.org/feed.xml",
      title: "Diag Feed",
      last_http_status: 200,
      last_ingestion_method: "poll",
      discovered_websub_hub: "https://hub.diag.example.org/"
    )
    UserFeedSubscription.create!(user: alice, feed: feed, subscribed_at: Time.current)
    item = FeedItem.create!(
      feed: feed,
      external_id: "d-1",
      title: "Diag Story",
      content_text: "Details",
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      content_hash: "h1"
    )

    # Bob (not subscribed) gets 403 on diagnostics and item state mutation
    post "/login", params: { email: bob.email, password: "password123!" }
    get "/feeds/#{feed.id}"
    expect(response).to have_http_status(:forbidden)
    patch "/items/#{item.id}/state", params: { saved: true }
    expect(response).to have_http_status(:forbidden)

    # Alice (subscribed) can view diagnostics and save/read privately
    delete "/logout"
    post "/login", params: { email: alice.email, password: "password123!" }
    get "/feeds/#{feed.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("https://hub.diag.example.org/")

    patch "/items/#{item.id}/state", params: { read: true, saved: true }
    expect(response).to redirect_to("/items/#{item.id}")
    ui = UserItem.find_by!(user: alice, feed_item: item)
    expect(ui).to be_read
    expect(ui).to be_saved
    expect(UserItem.where(user: bob)).to be_empty
  end
end
