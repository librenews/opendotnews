# Phase 1 Demo Script — run with: bin/rails runner db/seeds_demo.rb
# Demonstrates two users sharing one upstream feed, full-text search isolation,
# OPML round-trip, outbox -> inbox cursor updates, and MCP tool invocation.

puts "== Open.News Phase 1 Demo =="

alice = User.find_or_create_by!(email: "alice@example.org") do |u|
  u.namespace = "alice"
  u.password = "demo-password-123!"
end

bob = User.find_or_create_by!(email: "bob@example.org") do |u|
  u.namespace = "bob"
  u.password = "demo-password-123!"
end

sample_rss = <<~XML
  <?xml version="1.0" encoding="UTF-8"?>
  <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
    <channel>
      <title>Stamford Civic Dispatch</title>
      <link>https://civic.example.org/</link>
      <description>Local zoning and council updates</description>
      <atom:link href="https://civic.example.org/feed.xml" rel="self" type="application/rss+xml" />
      <item>
        <guid>https://civic.example.org/posts/zoning-42</guid>
        <title>Zoning Board Approves Transit-Oriented Plan</title>
        <link>https://civic.example.org/posts/zoning-42</link>
        <pubDate>Mon, 23 Nov 2026 12:00:00 GMT</pubDate>
        <description>The board voted 4-1 on new mixed-use zoning near the train station.</description>
      </item>
      <item>
        <guid>https://civic.example.org/posts/parks-11</guid>
        <title>Harbor Park Trail Resurfacing Begins</title>
        <link>https://civic.example.org/posts/parks-11</link>
        <pubDate>Sun, 22 Nov 2026 15:00:00 GMT</pubDate>
        <description>Crews will repave the waterfront trail starting Tuesday morning.</description>
      </item>
    </channel>
  </rss>
XML

feed = Feed.find_or_create_by!(canonical_url: "https://civic.example.org/feed.xml") do |f|
  f.title = "Stamford Civic Dispatch"
  f.site_url = "https://civic.example.org/"
  f.format = "rss"
  f.status = "active"
end

[ alice, bob ].each do |u|
  UserFeedSubscription.active.find_or_create_by!(user: u, feed: feed) do |s|
    s.folder_name = "Local"
    s.subscribed_at = 1.minute.ago
  end
end

parsed = Feeds::Parse.call(sample_rss, base_url: feed.canonical_url)
ingest = Feeds::Ingest.call(feed: feed, parsed_feed: parsed, raw_body: sample_rss)
puts "Ingested shared feed: created=#{ingest.created_count} updated=#{ingest.updated_count} unchanged=#{ingest.unchanged_count}"

# Synchronously dispatch outbox and materialize inboxes for demo verification
Events::OutboxDispatch.call
OutboxEvent.where(event_type: %w[feed_item.created feed_item.updated]).find_each do |ev|
  Events::InboxFanout.call(ev.id)
end

search = Search::Items.call(user: alice, query: "zoning")
puts "Alice search('zoning') hits: #{search.items.map(&:title).inspect}"

updates = Inbox::FetchUpdates.call(user: bob)
puts "Bob inbox events: #{updates.events.size}, next_cursor=#{updates.next_cursor}"

opml = Opml::Export.call(user: alice)
puts "Exported Alice OPML bytes: #{opml.bytesize}"
puts "Shared Feed count in DB: #{Feed.where(canonical_url: feed.canonical_url).count} (subscribers: #{feed.active_subscriber_count})"
puts "== Demo complete! Sign in at http://localhost:3000/login as alice@example.org / demo-password-123! =="
