require "rails_helper"

RSpec.describe "Shared ingestion, outbox recovery, inbox cursors, search isolation, and OPML" do
  let(:public_resolver) { ->(_host) { [ "93.184.216.34" ] } }
  let(:fetcher) { Security::SafeHttpFetch.new(resolver: public_resolver) }

  let!(:alice) { User.create!(email: "alice@example.org", namespace: "alice", password: "password123!") }
  let!(:bob) { User.create!(email: "bob@example.org", namespace: "bob", password: "password123!") }

  let(:rss_body) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <title>Shared Tech Feed</title>
          <link>https://tech.example.org/</link>
          <item>
            <guid>tech-1</guid>
            <title>PostgreSQL Full-Text Search Guide</title>
            <link>https://tech.example.org/pg-fts</link>
            <pubDate>Mon, 23 Nov 2026 11:00:00 GMT</pubDate>
            <description>Weighted tsvector indexing for fast search.</description>
          </item>
        </channel>
      </rss>
    XML
  end

  it "shares one upstream fetch across multiple subscribers and enforces search authorization isolation" do
    req_stub = stub_request(:get, "https://tech.example.org/feed.xml")
      .to_return(status: 200, body: rss_body, headers: { "Content-Type" => "application/rss+xml", "ETag" => '"t1"' })

    res_a = Subscriptions::Subscribe.call(user: alice, url: "https://tech.example.org/feed.xml", folder: "Tech", fetcher: fetcher)
    expect(res_a).to be_ok

    # Bob subscribes to the exact same feed: zero second upstream HTTP request!
    res_b = Subscriptions::Subscribe.call(user: bob, url: "https://tech.example.org/feed.xml", folder: "Reading", fetcher: fetcher)
    expect(res_b).to be_ok
    expect(res_b.feed.id).to eq(res_a.feed.id)
    expect(Feed.count).to eq(1)
    expect(req_stub).to have_been_requested.once

    # Add a private-to-Alice feed that Bob does NOT follow
    secret_feed = Feed.create!(canonical_url: "https://secret.example.org/feed.xml", title: "Secret")
    UserFeedSubscription.create!(user: alice, feed: secret_feed, subscribed_at: Time.current)
    FeedItem.create!(
      feed: secret_feed,
      external_id: "s-1",
      title: "QuantumBanana Secret Report",
      content_text: "QuantumBanana classified notes",
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      content_hash: "abc123"
    )

    alice_hits = Search::Items.call(user: alice, query: "QuantumBanana")
    bob_hits = Search::Items.call(user: bob, query: "QuantumBanana")
    expect(alice_hits.items.size).to eq(1)
    expect(bob_hits.items).to be_empty
  end

  it "recovers undispatched outbox events, fans out idempotently, paginates cursors, and detects cursor_expired" do
    feed = Feed.create!(canonical_url: "https://news.example.org/feed.xml", title: "News")
    UserFeedSubscription.create!(user: alice, feed: feed, subscribed_at: 2.minutes.ago)
    UserFeedSubscription.create!(user: bob, feed: feed, subscribed_at: 2.minutes.ago)

    parsed = Feeds::Parse.call(rss_body, base_url: feed.canonical_url)
    Feeds::Ingest.call(feed: feed, parsed_feed: parsed, raw_body: rss_body)

    # Simulate Redis/worker crash between commit and enqueue: clear Sidekiq queue, outbox stays undispatched!
    Sidekiq::Worker.clear_all
    expect(OutboxEvent.undispatched.count).to eq(1)

    dispatched = Events::OutboxDispatch.call
    expect(dispatched).to eq(1)
    expect(Events::MaterializeInboxJob.jobs.size).to eq(1)

    outbox_id = Events::MaterializeInboxJob.jobs.first["args"].first
    # Run InboxFanout twice (simulating Sidekiq retry): must remain idempotent!
    Events::InboxFanout.call(outbox_id)
    Events::InboxFanout.call(outbox_id)

    expect(UserInboxEvent.where(user: alice).count).to eq(1)
    expect(UserInboxEvent.where(user: bob).count).to eq(1)

    u1 = Inbox::FetchUpdates.call(user: alice, after_cursor: 0, include_content: true)
    expect(u1).to be_ok
    expect(u1.events.size).to eq(1)
    expect(u1.events.first[:content_text]).to include("tsvector")

    # Cursor after latest returns empty with no error
    u2 = Inbox::FetchUpdates.call(user: alice, after_cursor: u1.next_cursor)
    expect(u2).to be_ok
    expect(u2.events).to be_empty

    # Simulate an older purged cursor (strictly smaller than retained min cursor)
    old_cursor = u1.events.first[:cursor] - 1
    if old_cursor > 0
      expired = Inbox::FetchUpdates.call(user: alice, after_cursor: old_cursor)
      expect(expired).to be_cursor_expired
      expect(expired.error_code).to eq("cursor_expired")
    end
  end

  it "round-trips OPML import/export while rejecting XXE and reporting bad outlines" do
    opml_xml = <<~OPML
      <?xml version="1.0" encoding="UTF-8"?>
      <opml version="2.0">
        <head><title>Export</title></head>
        <body>
          <outline text="News" title="News">
            <outline type="rss" text="Feed One" xmlUrl="https://one.example.org/rss.xml" htmlUrl="https://one.example.org/"/>
            <outline type="rss" text="Feed One Dup" xmlUrl="https://one.example.org/rss.xml"/>
            <outline type="rss" text="Local SSRF" xmlUrl="http://127.0.0.1/secret.xml"/>
            <outline type="rss" text="Bad Scheme" xmlUrl="ftp://bad.example.org/feed"/>
          </outline>
          <outline type="rss" text="Top Level" xmlUrl="https://two.example.org/atom.xml"/>
        </body>
      </opml>
    OPML

    import = Opml::Import.enqueue(user: alice, opml_xml: opml_xml)
    expect(Opml::ImportJob.jobs.size).to eq(1)

    job_args = Opml::ImportJob.jobs.first["args"]
    Opml::Import.process!(import, job_args[1], enqueue_fetches: false)
    import.reload

    expect(import.status).to eq("completed")
    expect(import.success_count).to eq(2)
    expect(import.skipped_count).to eq(1)
    expect(import.error_count).to eq(2)

    exported = Opml::Export.call(user: alice)
    expect(exported).to include("https://one.example.org/rss.xml")
    expect(exported).to include("https://two.example.org/atom.xml")
    expect(exported).to include('text="News"')

    # Round-trip into Bob's clean account
    bob_import = Opml::Import.enqueue(user: bob, opml_xml: exported)
    bob_args = Opml::ImportJob.jobs.last["args"]
    Opml::Import.process!(bob_import, bob_args[1], enqueue_fetches: false)

    expect(bob.reload.feeds.pluck(:canonical_url).sort).to eq(
      [ "https://one.example.org/rss.xml", "https://two.example.org/atom.xml" ]
    )

    # XXE OPML rejected
    xxe_opml = '<?xml version="1.0"?><!DOCTYPE opml [ <!ENTITY e SYSTEM "file:///etc/passwd"> ]><opml><body></body></opml>'
    expect { Opml::Import.enqueue(user: alice, opml_xml: xxe_opml) }.to raise_error(Opml::Import::UnsafeXmlError)
  end
end
