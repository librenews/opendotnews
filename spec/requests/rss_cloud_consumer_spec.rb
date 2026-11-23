require "rails_helper"

RSpec.describe "Phase 2 rssCloud Consumer (REST + XML-RPC)", type: :request do
  let(:public_resolver) { ->(_host) { [ "93.184.216.34" ] } }
  let(:fetcher) { Security::SafeHttpFetch.new(resolver: public_resolver) }

  let!(:alice) { User.create!(email: "rc_alice@example.org", namespace: "rc_alice", password: "password123!") }

  let!(:rest_feed) do
    Feed.create!(
      canonical_url: "https://dave.example.org/rss.xml",
      title: "Scripting Notes",
      discovered_rsscloud_endpoint: "http://rpc.rsscloud.io/pleaseNotify",
      discovered_rsscloud_protocol: "http-post"
    )
  end

  let!(:xmlrpc_feed) do
    Feed.create!(
      canonical_url: "https://xmlrpc.example.org/rss.xml",
      title: "XML-RPC Notes",
      discovered_rsscloud_endpoint: "http://cloud.example.org/RPC2",
      discovered_rsscloud_protocol: "xml-rpc",
      source_metadata: { "rsscloud_register_procedure" => "rssCloud.pleaseNotify" }
    )
  end

  before do
    UserFeedSubscription.create!(user: alice, feed: rest_feed, subscribed_at: 2.minutes.ago)
    UserFeedSubscription.create!(user: alice, feed: xmlrpc_feed, subscribed_at: 2.minutes.ago)
  end

  it "registers REST http-post rssCloud, verifies challenge, coalesces repeated pings, and rejects unknown topics" do
    reg_stub = stub_request(:post, "http://rpc.rsscloud.io/pleaseNotify")
      .with { |req|
        params = URI.decode_www_form(req.body).to_h
        params["protocol"] == "http-post" &&
          params["url1"] == "https://dave.example.org/rss.xml" &&
          params["path"].start_with?("/callbacks/rsscloud/")
      }
      .to_return(status: 200, body: '<notifyResult success="true" msg="Thanks for the registration."/>', headers: { "Content-Type" => "text/xml" })

    expect(Push::Reconciler.reconcile_feed(rest_feed, fetcher: fetcher)).to eq(:rsscloud)
    expect(reg_stub).to have_been_requested.once

    sub = UpstreamPushSubscription.find_by!(feed: rest_feed, protocol: "rsscloud")
    expect(sub.status).to eq("active")
    # 25-hour expiry convention, renew within 24 hours
    expect(sub.lease_seconds).to eq(25.hours.to_i)
    expect(sub.next_renew_at).to be < 24.hours.from_now

    # Challenge verification echoes challenge and rejects mismatched URL
    get "/callbacks/rsscloud/#{sub.callback_token}", params: { url: rest_feed.canonical_url, challenge: "rc-chal-99" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq("rc-chal-99")

    get "/callbacks/rsscloud/#{sub.callback_token}", params: { url: "https://evil.example/rss.xml", challenge: "rc-chal-99" }
    expect(response).to have_http_status(:forbidden)

    # Burst of 3 identical REST pings coalesces into ONE Feeds::FetchJob!
    3.times do
      post "/callbacks/rsscloud/#{sub.callback_token}",
        params: "url=#{CGI.escape(rest_feed.canonical_url)}",
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
      expect(response).to have_http_status(:ok)
    end
    expect(Feeds::FetchJob.jobs.size).to eq(1)
    expect(Feeds::FetchJob.jobs.first["args"]).to eq([ rest_feed.id ])

    # Malicious ping for an unregistered/arbitrary topic URL is rejected and never triggers fetch
    post "/callbacks/rsscloud/#{sub.callback_token}",
      params: "url=#{CGI.escape("https://victim.internal/rss.xml")}",
      headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    expect(response).to have_http_status(:forbidden)
    expect(Feeds::FetchJob.jobs.size).to eq(1)
  end

  it "supports XML-RPC rssCloud registration, XML-RPC ping callbacks, XXE rejection, and renewal" do
    xmlrpc_ok = '<?xml version="1.0"?><methodResponse><params><param><value><boolean>1</boolean></value></param></params></methodResponse>'
    reg_stub = stub_request(:post, "http://cloud.example.org/RPC2")
      .with { |req|
        req.body.include?("<methodName>rssCloud.pleaseNotify</methodName>") &&
          req.body.include?("https://xmlrpc.example.org/rss.xml")
      }
      .to_return(status: 200, body: xmlrpc_ok, headers: { "Content-Type" => "text/xml" })

    res = RssCloud::Consumer.register(xmlrpc_feed, fetcher: fetcher)
    expect(res).to be_ok
    expect(reg_stub).to have_been_requested.once
    sub = res.subscription

    # Valid XML-RPC ping callback
    ping_xml = <<~XML
      <?xml version="1.0"?>
      <methodCall>
        <methodName>rssPleaseNotify</methodName>
        <params>
          <param><value><string>https://xmlrpc.example.org/rss.xml</string></value></param>
        </params>
      </methodCall>
    XML
    post "/callbacks/rsscloud/#{sub.callback_token}",
      params: ping_xml,
      headers: { "CONTENT_TYPE" => "text/xml" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("<boolean>1</boolean>")
    expect(Feeds::FetchJob.jobs.size).to eq(1)

    # XXE ping payload is rejected cleanly (400)
    xxe_ping = '<?xml version="1.0"?><!DOCTYPE x [ <!ENTITY e SYSTEM "file:///etc/passwd"> ]><methodCall><params><param><value><string>&e;</string></value></param></params></methodCall>'
    post "/callbacks/rsscloud/#{sub.callback_token}",
      params: xxe_ping,
      headers: { "CONTENT_TYPE" => "text/xml" }
    expect(response).to have_http_status(:bad_request)

    # Renewal runs cleanly when due
    sub.update!(next_renew_at: 5.minutes.ago)
    Push::Reconciler.renew_due!(fetcher: fetcher)
    expect(reg_stub).to have_been_requested.twice
  end
end
