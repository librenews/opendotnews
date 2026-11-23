require "rails_helper"
require "zlib"
require "stringio"

RSpec.describe Security::SafeHttpFetch do
  let(:public_resolver) { ->(_host) { [ "93.184.216.34" ] } }

  describe ".blocked_ip?" do
    it "blocks loopback, private, link-local, metadata, CGNAT, and mapped IPv6 addresses" do
      blocked = %w[
        127.0.0.1 10.0.0.5 172.16.1.2 192.168.1.1 169.254.169.254
        100.64.0.1 0.0.0.0 ::1 fe80::1 fc00::1 fd00:ec2::254 ::ffff:127.0.0.1
      ]
      blocked.each do |ip|
        expect(described_class.blocked_ip?(ip)).to be(true), "expected #{ip} to be blocked"
      end
    end

    it "allows public IPv4 and IPv6 addresses" do
      %w[93.184.216.34 1.1.1.1 2606:2800:220:1:248:1893:25c8:1946].each do |ip|
        expect(described_class.blocked_ip?(ip)).to be(false), "expected #{ip} to be allowed"
      end
    end
  end

  describe "#get" do
    it "rejects non-HTTP(S) schemes and userinfo" do
      fetcher = described_class.new(resolver: public_resolver)
      expect { fetcher.get("file:///etc/passwd") }.to raise_error(Security::SafeHttpFetch::InvalidUrlError)
      expect { fetcher.get("https://user:pass@example.org/feed.xml") }.to raise_error(Security::SafeHttpFetch::InvalidUrlError)
    end

    it "blocks DNS rebinding to loopback or metadata IPs" do
      evil_resolver = ->(_host) { [ "93.184.216.34", "169.254.169.254" ] }
      fetcher = described_class.new(resolver: evil_resolver)
      expect { fetcher.get("https://rebind.evil.example/feed.xml") }.to raise_error(Security::SafeHttpFetch::SsrfBlockedError)
    end

    it "blocks redirects that jump to private or loopback destinations" do
      stub_request(:get, "https://pub.example.org/start")
        .to_return(status: 302, headers: { "Location" => "http://127.0.0.1:8080/internal" })

      fetcher = described_class.new(resolver: public_resolver)
      expect { fetcher.get("https://pub.example.org/start") }.to raise_error(Security::SafeHttpFetch::SsrfBlockedError)
    end

    it "enforces maximum redirect hops" do
      stub_request(:get, "https://pub.example.org/a").to_return(status: 302, headers: { "Location" => "/b" })
      stub_request(:get, "https://pub.example.org/b").to_return(status: 302, headers: { "Location" => "/c" })
      stub_request(:get, "https://pub.example.org/c").to_return(status: 200, body: "ok")

      fetcher = described_class.new(resolver: public_resolver, max_redirects: 1)
      expect { fetcher.get("https://pub.example.org/a") }.to raise_error(Security::SafeHttpFetch::TooManyRedirectsError)
    end

    it "enforces raw byte cap and gzip decompression bomb cap" do
      stub_request(:get, "https://pub.example.org/huge").to_return(status: 200, body: "a" * 500)
      fetcher = described_class.new(resolver: public_resolver, max_bytes: 100)
      expect { fetcher.get("https://pub.example.org/huge") }.to raise_error(Security::SafeHttpFetch::ResponseTooLargeError)

      # Highly compressible payload exceeding decompressed cap while under raw wire cap
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io)
      gz.write("A" * 50_000)
      gz.close
      compressed = io.string
      expect(compressed.bytesize).to be < 1000

      stub_request(:get, "https://pub.example.org/bomb")
        .to_return(status: 200, body: compressed, headers: { "Content-Encoding" => "gzip" })

      bomb_fetcher = described_class.new(resolver: public_resolver, max_bytes: 5_000, max_decompressed_bytes: 2_000)
      expect { bomb_fetcher.get("https://pub.example.org/bomb") }.to raise_error(Security::SafeHttpFetch::ResponseTooLargeError)
    end

    it "sends conditional GET headers and handles 304 Not Modified" do
      stub_request(:get, "https://pub.example.org/feed.xml")
        .with(headers: { "If-None-Match" => '"v1"', "If-Modified-Since" => "Mon, 23 Nov 2026 00:00:00 GMT" })
        .to_return(status: 304)

      fetcher = described_class.new(resolver: public_resolver)
      resp = fetcher.get("https://pub.example.org/feed.xml", etag: '"v1"', last_modified: "Mon, 23 Nov 2026 00:00:00 GMT")
      expect(resp).to be_not_modified
      expect(resp.body).to eq("")
    end
  end
end
