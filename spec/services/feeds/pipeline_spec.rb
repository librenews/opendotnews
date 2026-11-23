require "rails_helper"

RSpec.describe "Feed discovery, parsing, normalization, and ingestion" do
  let(:public_resolver) { ->(_host) { [ "93.184.216.34" ] } }
  let(:fetcher) { Security::SafeHttpFetch.new(resolver: public_resolver) }

  let(:rss_xml) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <channel>
          <title>Civic Feed</title>
          <link>https://civic.example.org/</link>
          <description>News</description>
          <atom:link href="https://civic.example.org/feed.xml" rel="self" type="application/rss+xml"/>
          <atom:link href="https://hub.example.org/" rel="hub"/>
          <cloud domain="rpc.rsscloud.io" port="80" path="/pleaseNotify" registerProcedure="" protocol="http-post"/>
          <item>
            <guid isPermaLink="false">post-1</guid>
            <title>Board Meeting &amp; Agenda</title>
            <link>/posts/1</link>
            <dc:creator>Jane Doe</dc:creator>
            <pubDate>Mon, 23 Nov 2026 10:00:00 GMT</pubDate>
            <description>Short summary</description>
            <content:encoded><![CDATA[<p>Hello <a href="javascript:alert(1)" onclick="evil()">bad</a><script>alert(2)</script> world</p>]]></content:encoded>
          </item>
        </channel>
      </rss>
    XML
  end

  let(:atom_xml) do
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Atom Journal</title>
        <link href="https://atom.example.org/" rel="alternate"/>
        <link href="https://atom.example.org/feed.atom" rel="self"/>
        <entry>
          <id>urn:uuid:atom-entry-1</id>
          <title>Unicode Café ☕</title>
          <link href="/entries/1" rel="alternate"/>
          <published>2026-11-23T08:00:00Z</published>
          <updated>2026-11-23T09:00:00Z</updated>
          <author><name>Alex</name></author>
          <summary>Atom summary text</summary>
        </entry>
      </feed>
    XML
  end

  it "parses RSS 2.0 and Atom 1.0 including WebSub/rssCloud metadata and sanitizes XSS" do
    parsed = Feeds::Parse.call(rss_xml, base_url: "https://civic.example.org/feed.xml")
    expect(parsed.format).to eq("rss")
    expect(parsed.websub_hub).to eq("https://hub.example.org/")
    expect(parsed.rsscloud_endpoint).to eq("http://rpc.rsscloud.io/pleaseNotify")
    expect(parsed.rsscloud_protocol).to eq("http-post")

    norm = Feeds::Normalize.call(parsed, feed_url: "https://civic.example.org/feed.xml")
    expect(norm.size).to eq(1)
    item = norm.first
    expect(item.external_id).to eq("post-1")
    expect(item.external_url).to eq("https://civic.example.org/posts/1")
    expect(item.author).to eq("Jane Doe")
    expect(item.content_html_sanitized).not_to include("<script")
    expect(item.content_html_sanitized).not_to include("javascript:")
    expect(item.content_html_sanitized).not_to include("onclick")

    atom_parsed = Feeds::Parse.call(atom_xml, base_url: "https://atom.example.org/feed.atom")
    expect(atom_parsed.format).to eq("atom")
    atom_norm = Feeds::Normalize.call(atom_parsed, feed_url: "https://atom.example.org/feed.atom")
    expect(atom_norm.first.title).to eq("Unicode Café ☕")
    expect(atom_norm.first.external_id).to eq("urn:uuid:atom-entry-1")
    expect(atom_norm.first.external_url).to eq("https://atom.example.org/entries/1")
  end

  it "rejects XXE / external DTD XML payloads" do
    xxe = <<~XML
      <?xml version="1.0"?>
      <!DOCTYPE rss [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
      <rss version="2.0"><channel><title>&xxe;</title></channel></rss>
    XML
    expect { Feeds::Parse.call(xxe) }.to raise_error(Feeds::Parse::UnsafeXmlError)
  end

  it "discovers a single feed or returns selection_required when multiple feeds are advertised" do
    html_multi = <<~HTML
      <html><head>
        <link rel="alternate" type="application/rss+xml" title="Posts RSS" href="/posts.xml">
        <link rel="alternate" type="application/atom+xml" title="Comments Atom" href="/comments.atom">
      </head></html>
    HTML
    stub_request(:get, "https://multi.example.org/").to_return(status: 200, body: html_multi, headers: { "Content-Type" => "text/html" })

    res = Feeds::Discover.call("https://multi.example.org/", fetcher: fetcher)
    expect(res).to be_selection_required
    expect(res.candidates.map(&:url)).to eq([ "https://multi.example.org/posts.xml", "https://multi.example.org/comments.atom" ])
  end

  it "tracks item revisions on content changes without duplicating items or losing history on 500/empty" do
    feed = Feed.create!(canonical_url: "https://civic.example.org/feed.xml")
    parsed1 = Feeds::Parse.call(rss_xml, base_url: feed.canonical_url)

    r1 = Feeds::Ingest.call(feed: feed, parsed_feed: parsed1, raw_body: rss_xml, etag: '"e1"')
    expect(r1.created_count).to eq(1)
    expect(OutboxEvent.where(event_type: "feed_item.created").count).to eq(1)

    # Identical re-ingest creates no revisions or outbox events
    r2 = Feeds::Ingest.call(feed: feed, parsed_feed: parsed1, raw_body: rss_xml, etag: '"e1"')
    expect(r2.unchanged_count).to eq(1)
    expect(FeedItemRevision.count).to eq(1)
    expect(OutboxEvent.count).to eq(1)

    # Revised body increments revision & emits feed_item.updated while preserving original published_at
    original_pub = FeedItem.first.published_at
    revised_rss = rss_xml.sub("Short summary", "Updated detailed summary")
    parsed2 = Feeds::Parse.call(revised_rss, base_url: feed.canonical_url)
    r3 = Feeds::Ingest.call(feed: feed, parsed_feed: parsed2, raw_body: revised_rss, etag: '"e2"')
    expect(r3.updated_count).to eq(1)
    expect(FeedItem.count).to eq(1)
    expect(FeedItem.first.current_revision_number).to eq(2)
    expect(FeedItem.first.published_at).to eq(original_pub)
    expect(OutboxEvent.where(event_type: "feed_item.updated").count).to eq(1)

    # Upstream 500 increments failure count and preserves archived items
    stub_request(:get, "https://civic.example.org/feed.xml").to_return(status: 500, body: "boom")
    fetch_res = Feeds::Fetch.call(feed, fetcher: fetcher)
    expect(fetch_res.status).to eq(:error)
    expect(feed.reload.fetch_failure_count).to eq(1)
    expect(FeedItem.count).to eq(1)
  end
end
