require "rails_helper"
require "openssl"

RSpec.describe "Phase 4 Downstream Real-Time Syndication (WebSub Hub & rssCloud Cloud Server)", type: :request do
  let(:public_resolver) { ->(_host) { [ "93.184.216.34" ] } }
  let(:fetcher) { Security::SafeHttpFetch.new(resolver: public_resolver) }

  let!(:author) { User.create!(email: "author_p4@example.org", namespace: "authorp4", password: "password123!") }
  let(:base_url) { OpenNews.config.app_base_url }
  let(:rss_topic) { "#{base_url}/authorp4/feed.xml" }
  let(:atom_topic) { "#{base_url}/authorp4/feed.atom" }

  describe "WebSub Hub (POST /websub/hub)" do
    it "rejects non-owned external topics, private publications, SSRF callbacks, and >=200-byte secrets" do
      # External topic rejected
      post "/websub/hub", params: {
        "hub.mode" => "subscribe",
        "hub.topic" => "https://other.example.com/feed.xml",
        "hub.callback" => "https://sub.example.org/hook"
      }
      expect(response).to have_http_status(:bad_request)

      # Private publication rejected
      author.default_publication.update!(visibility: "private")
      post "/websub/hub", params: {
        "hub.mode" => "subscribe",
        "hub.topic" => rss_topic,
        "hub.callback" => "https://sub.example.org/hook"
      }
      expect(response).to have_http_status(:bad_request)
      author.default_publication.update!(visibility: "public")

      # Loopback / IMDS SSRF callback rejected
      %w[http://127.0.0.1:8080/cb http://localhost/cb http://169.254.169.254/latest/meta-data].each do |bad_cb|
        post "/websub/hub", params: {
          "hub.mode" => "subscribe",
          "hub.topic" => rss_topic,
          "hub.callback" => bad_cb
        }
        expect(response).to have_http_status(:bad_request)
      end

      # Secret >= 200 bytes rejected (W3C WebSub Section 5.1)
      post "/websub/hub", params: {
        "hub.mode" => "subscribe",
        "hub.topic" => rss_topic,
        "hub.callback" => "https://sub.example.org/hook",
        "hub.secret" => "a" * 200
      }
      expect(response).to have_http_status(:bad_request)
      expect(DownstreamSubscription.count).to eq(0)
    end

    it "verifies subscriber intent via GET challenge, clamps finite leases, encrypts secrets, and supports unsubscribe" do
      allow(Security::SafeHttpFetch).to receive(:new).and_return(fetcher)

      secret = "super-secret-websub-key-123"
      post "/websub/hub", params: {
        "hub.mode" => "subscribe",
        "hub.topic" => atom_topic,
        "hub.callback" => "https://reader.example.org/websub-hook",
        "hub.secret" => secret,
        "hub.lease_seconds" => "99999999" # should clamp to MAX_LEASE_SECONDS (finite)
      }
      expect(response).to have_http_status(:accepted)
      expect(WebSub::VerifySubscriptionJob.jobs.size).to eq(1)

      sub = DownstreamSubscription.last
      expect(sub.status).to eq("pending")
      expect(sub.topic_format).to eq("atom")
      expect(sub.lease_seconds).to eq(WebSub::Hub::MAX_LEASE_SECONDS)

      # Verify secret is encrypted at rest
      raw_secret = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT secret FROM downstream_subscriptions WHERE id = ?", sub.id ])
      )
      expect(raw_secret).not_to eq(secret)

      # Stub GET verification echoing exact hub.challenge
      verify_stub = stub_request(:get, %r{\Ahttps://reader\.example\.org/websub-hook\?})
        .with(query: hash_including("hub.mode" => "subscribe"))
        .to_return { |req|
          q = URI.decode_www_form(URI.parse(req.uri.to_s).query).to_h
          expect(q["hub.topic"]).to eq(atom_topic)
          expect(q["hub.lease_seconds"].to_i).to eq(WebSub::Hub::MAX_LEASE_SECONDS)
          { status: 200, body: q["hub.challenge"] }
        }

      args = WebSub::VerifySubscriptionJob.jobs.first["args"]
      WebSub::VerifySubscriptionJob.new.perform(*args)
      expect(verify_stub).to have_been_requested.once

      sub.reload
      expect(sub.status).to eq("active")
      expect(sub.lease_expires_at).to be_present
      expect(sub.lease_expires_at).to be <= (WebSub::Hub::MAX_LEASE_SECONDS.seconds.from_now + 5.seconds)

      # Unsubscribe with challenge verification
      WebSub::VerifySubscriptionJob.clear
      unsub_stub = stub_request(:get, %r{\Ahttps://reader\.example\.org/websub-hook\?})
        .with(query: hash_including("hub.mode" => "unsubscribe"))
        .to_return { |req|
          q = URI.decode_www_form(URI.parse(req.uri.to_s).query).to_h
          { status: 200, body: q["hub.challenge"] }
        }

      post "/websub/hub", params: {
        "hub.mode" => "unsubscribe",
        "hub.topic" => atom_topic,
        "hub.callback" => "https://reader.example.org/websub-hook"
      }
      expect(response).to have_http_status(:accepted)
      WebSub::VerifySubscriptionJob.new.perform(*WebSub::VerifySubscriptionJob.jobs.first["args"])
      expect(unsub_stub).to have_been_requested.once
      expect(sub.reload.status).to eq("unsubscribed")
    end

    it "does not activate subscription when challenge verification fails" do
      allow(Security::SafeHttpFetch).to receive(:new).and_return(fetcher)

      post "/websub/hub", params: {
        "hub.mode" => "subscribe",
        "hub.topic" => rss_topic,
        "hub.callback" => "https://bad-reader.example.org/hook"
      }
      expect(response).to have_http_status(:accepted)

      stub_request(:get, %r{\Ahttps://bad-reader\.example\.org/hook\?})
        .to_return(status: 200, body: "wrong-challenge")

      WebSub::VerifySubscriptionJob.new.perform(*WebSub::VerifySubscriptionJob.jobs.first["args"])
      expect(DownstreamSubscription.last.status).to eq("expired")
    end
  end

  describe "rssCloud Cloud Server (POST /rsscloud/pleaseNotify, /rsscloud/RPC2, /rsscloud/ping)" do
    it "registers REST and XML-RPC subscribers after challenge verification, rejects unowned topics, SSRF, and XXE" do
      # Reject SSRF loopback callback (real SafeHttpFetch blocks 127.0.0.1)
      post "/rsscloud/pleaseNotify", params: {
        "domain" => "127.0.0.1",
        "port" => "8080",
        "path" => "/notify",
        "protocol" => "http-post",
        "url1" => rss_topic
      }
      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include('success="false"')

      allow(Security::SafeHttpFetch).to receive(:new).and_return(fetcher)

      # Reject unowned external topic
      post "/rsscloud/pleaseNotify", params: {
        "domain" => "agg.example.org",
        "port" => "443",
        "path" => "/rsscloud-cb",
        "protocol" => "http-post",
        "url1" => "https://unowned.example.com/feed.xml"
      }
      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include('success="false"')

      # Valid REST http-post registration with challenge echo
      rest_challenge_stub = stub_request(:get, %r{\Ahttps://agg\.example\.org/rsscloud-cb\?})
        .to_return { |req|
          q = URI.decode_www_form(URI.parse(req.uri.to_s).query).to_h
          expect(q["url"]).to eq(rss_topic)
          { status: 200, body: q["challenge"] }
        }

      post "/rsscloud/pleaseNotify", params: {
        "domain" => "agg.example.org",
        "port" => "443",
        "path" => "/rsscloud-cb",
        "protocol" => "http-post",
        "url1" => rss_topic
      }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('success="true"')
      expect(rest_challenge_stub).to have_been_requested.once

      rest_sub = DownstreamSubscription.find_by!(protocol: "rsscloud", callback_host: "agg.example.org")
      expect(rest_sub.status).to eq("active")
      expect(rest_sub.lease_seconds).to eq(25.hours.to_i)
      expect(rest_sub.lease_expires_at).to be > 24.hours.from_now

      # Reject XXE on /rsscloud/RPC2
      xxe_xml = <<~XML
        <?xml version="1.0"?>
        <!DOCTYPE methodCall [ <!ENTITY xxe SYSTEM "file:///etc/passwd"> ]>
        <methodCall><methodName>rssCloud.pleaseNotify</methodName><params></params></methodCall>
      XML
      post "/rsscloud/RPC2", params: xxe_xml, headers: { "CONTENT_TYPE" => "text/xml" }
      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("fault")

      # Valid XML-RPC pleaseNotify registration
      xmlrpc_challenge_stub = stub_request(:get, %r{\Ahttps://xmlrpc\.example\.org/RPC2\?})
        .to_return { |req|
          q = URI.decode_www_form(URI.parse(req.uri.to_s).query).to_h
          { status: 200, body: q["challenge"] }
        }

      rpc_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <methodCall>
          <methodName>rssCloud.pleaseNotify</methodName>
          <params>
            <param><value><string>myAggregator.feedUpdated</string></value></param>
            <param><value><int>443</int></value></param>
            <param><value><string>/RPC2</string></value></param>
            <param><value><string>xml-rpc</string></value></param>
            <param><value><array><data><value><string>#{rss_topic}</string></value></data></array></value></param>
            <param><value><string>xmlrpc.example.org</string></value></param>
          </params>
        </methodCall>
      XML
      post "/rsscloud/RPC2", params: rpc_xml, headers: { "CONTENT_TYPE" => "text/xml" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<boolean>1</boolean>")
      expect(xmlrpc_challenge_stub).to have_been_requested.once

      rpc_sub = DownstreamSubscription.find_by!(protocol: "rsscloud", callback_host: "xmlrpc.example.org")
      expect(rpc_sub.metadata["protocol_variant"]).to eq("xml-rpc")
      expect(rpc_sub.metadata["notify_procedure"]).to eq("myAggregator.feedUpdated")

      # Guarded /rsscloud/ping rejects arbitrary remote URLs (403) and accepts hosted feed URL (200)
      post "/rsscloud/ping", params: { "url" => "https://arbitrary.example.com/feed.xml" }
      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include('success="false"')

      post "/rsscloud/ping", params: { "url" => rss_topic }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('success="true"')
    end
  end

  describe "End-to-End Publication Fanout, Fat Push + Lightweight Ping, Retries, 410 Gone, Expiry, and Dashboard" do
    it "fans out a single publication change to both WebSub (signed full XML) and rssCloud (lightweight feed URL ping), retries transient errors, handles 410 Gone, and expires leases" do
      allow(Security::SafeHttpFetch).to receive(:new).and_return(fetcher)

      pub = author.default_publication
      ws_secret = "hmac-shared-secret-xyz"

      ws_sub = DownstreamSubscription.create!(
        publication: pub,
        protocol: "websub",
        topic_url: atom_topic,
        topic_format: "atom",
        callback_url: "https://ws-sub.example.org/receive",
        callback_host: "ws-sub.example.org",
        secret: ws_secret,
        status: "active",
        lease_seconds: 86_400,
        lease_expires_at: 1.day.from_now
      )

      rc_rest_sub = DownstreamSubscription.create!(
        publication: pub,
        protocol: "rsscloud",
        topic_url: rss_topic,
        topic_format: "rss",
        callback_url: "https://rc-rest.example.org/ping",
        callback_host: "rc-rest.example.org",
        status: "active",
        lease_seconds: 25.hours.to_i,
        lease_expires_at: 25.hours.from_now,
        metadata: { "protocol_variant" => "http-post" }
      )

      rc_rpc_sub = DownstreamSubscription.create!(
        publication: pub,
        protocol: "rsscloud",
        topic_url: rss_topic,
        topic_format: "rss",
        callback_url: "https://rc-rpc.example.org/RPC2",
        callback_host: "rc-rpc.example.org",
        status: "active",
        lease_seconds: 25.hours.to_i,
        lease_expires_at: 25.hours.from_now,
        metadata: { "protocol_variant" => "xml-rpc", "notify_procedure" => "rssPleaseNotify" }
      )

      # Publish a public Markdown document -> emits ONE publication.feed_changed outbox event
      inbox_before = UserInboxEvent.count
      Publishing::CreateOrRevise.create(
        user: author,
        path: "updates/phase4-launch",
        title: "Phase 4 Syndication Launch",
        markdown: "# Phase 4 Launch\n\nReal-time WebSub + rssCloud fanout is live.",
        visibility: "public"
      )

      feed_events = OutboxEvent.where(event_type: "publication.feed_changed")
      expect(feed_events.count).to eq(1)
      event = feed_events.first

      # Dispatch outbox -> enqueues Publishing::FanoutFeedChangeJob (no duplicate user inbox rows)
      Events::OutboxDispatch.call
      expect(UserInboxEvent.count).to eq(inbox_before)
      expect(Publishing::FanoutFeedChangeJob.jobs.size).to eq(1)

      # Run fanout twice (idempotency check: second call enqueues 0 duplicates)
      expect(Events::PublicationFanout.call(event.id)).to eq(3)
      expect(Events::PublicationFanout.call(event.id)).to eq(0)
      expect(WebSub::DeliverContentJob.jobs.size).to eq(1)
      expect(RssCloud::DeliverPingJob.jobs.size).to eq(2)

      # 1. WebSub fat-push: FIRST attempt gets transient 503 -> retry_scheduled -> RetryDueJob retries -> 200 delivered with valid HMAC!
      received_ws_headers = nil
      received_ws_body = nil
      ws_attempts = 0
      stub_request(:post, "https://ws-sub.example.org/receive")
        .to_return { |req|
          ws_attempts += 1
          received_ws_headers = req.headers
          received_ws_body = req.body
          ws_attempts == 1 ? { status: 503, body: "try later", headers: { "Retry-After" => "30" } } : { status: 200, body: "ok" }
        }

      WebSub::DeliverContentJob.new.perform(*WebSub::DeliverContentJob.jobs.first["args"])
      first_attempt = DeliveryAttempt.find_by!(downstream_subscription: ws_sub, outbox_event: event, attempt_number: 1)
      expect(first_attempt.status).to eq("retry_scheduled")
      expect(first_attempt.http_status).to eq(503)
      expect(first_attempt.next_attempt_at).to be_present

      # Advance attempt's next_attempt_at to due and run Delivery::RetryDueJob
      first_attempt.update!(next_attempt_at: 1.second.ago)
      WebSub::DeliverContentJob.clear
      expect(Delivery::RetryDueJob.new.perform).to eq(1)
      expect(first_attempt.reload.status).to eq("failed")
      expect(WebSub::DeliverContentJob.jobs.size).to eq(1)

      # Execute retry attempt #2 -> succeeds with full Atom XML + valid X-Hub-Signature
      WebSub::DeliverContentJob.new.perform(*WebSub::DeliverContentJob.jobs.first["args"])
      second_attempt = DeliveryAttempt.find_by!(downstream_subscription: ws_sub, outbox_event: event, attempt_number: 2)
      expect(second_attempt.status).to eq("delivered")
      expect(second_attempt.http_status).to eq(200)
      expect(ws_sub.reload.last_delivered_at).to be_present

      expected_sig = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', ws_secret, received_ws_body)}"
      expect(received_ws_headers["X-Hub-Signature"]).to eq(expected_sig)
      expect(received_ws_headers["Content-Type"]).to include("application/atom+xml")
      expect(received_ws_headers["Link"]).to include('rel="hub"')
      expect(received_ws_body).to include("Phase 4 Syndication Launch")
      expect(received_ws_body).to include("<feed")

      # 2. rssCloud REST ping: receives ONLY form-encoded feed URL (never Markdown/JSON) -> 200 OK
      rc_rest_stub = stub_request(:post, "https://rc-rest.example.org/ping")
        .with { |req|
          req.headers["Content-Type"].include?("application/x-www-form-urlencoded") &&
            URI.decode_www_form(req.body).to_h == { "url" => rss_topic }
        }
        .to_return(status: 200, body: "thanks")

      # 3. rssCloud XML-RPC ping: receives XML-RPC with feed URL, responds 410 Gone -> auto-unsubscribes!
      rc_rpc_stub = stub_request(:post, "https://rc-rpc.example.org/RPC2")
        .with { |req|
          req.headers["Content-Type"].include?("text/xml") &&
            req.body.include?("<methodName>rssPleaseNotify</methodName>") &&
            req.body.include?(rss_topic) &&
            !req.body.include?("Phase 4 Launch")
        }
        .to_return(status: 410, body: "gone")

      RssCloud::DeliverPingJob.jobs.each { |j| RssCloud::DeliverPingJob.new.perform(*j["args"]) }
      expect(rc_rest_stub).to have_been_requested.once
      expect(rc_rpc_stub).to have_been_requested.once

      expect(DeliveryAttempt.find_by!(downstream_subscription: rc_rest_sub, outbox_event: event).status).to eq("delivered")
      expect(rc_rpc_sub.reload.status).to eq("unsubscribed")

      # 4. Lease expiration job expires lapsed subscriptions so they no longer receive fanout
      ws_sub.update!(lease_expires_at: 1.minute.ago)
      expect(Maintenance::ExpireLeasesJob.new.perform).to eq(1)
      expect(ws_sub.reload.status).to eq("expired")
      expect(DownstreamSubscription.deliverable.where(publication: pub)).to contain_exactly(rc_rest_sub)

      # 5. Delivery status dashboard renders for authenticated publication owner
      post "/login", params: { email: author.email, password: "password123!" }
      get "/publishing/deliveries"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ws-sub.example.org")
      expect(response.body).to include("rc-rest.example.org")
      expect(response.body).to include("delivered")
      expect(response.body).to include("unsubscribed")
    end
  end
end
