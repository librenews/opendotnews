package delivery

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strconv"
	"testing"
	"time"

	"github.com/librenews/opendotnews/internal/config"
	"github.com/librenews/opendotnews/internal/domain"
)

func TestEnvelopeBytePreservation(t *testing.T) {
	// JSON payload with specific key order and formatting.
	rawJSON := []byte(`{"z":1,"a":"hello","nested":[true,null]}`)
	evJSON := domain.Event{
		EventID:     "evt_1",
		Channel:     "@alice/news",
		PublishedAt: time.Now().UTC(),
		ContentType: "application/json",
		Payload:     rawJSON,
	}
	wire, err := MarshalEventEnvelope(evJSON)
	if err != nil {
		t.Fatalf("marshal json envelope: %v", err)
	}
	var decoded Envelope
	if err := json.Unmarshal(wire, &decoded); err != nil {
		t.Fatalf("unmarshal json envelope: %v", err)
	}
	if decoded.EnvelopeVersion != 1 || decoded.PayloadEncoding != "" {
		t.Fatalf("unexpected envelope metadata: %+v", decoded)
	}
	gotJSON, err := DecodeEnvelopePayload(decoded)
	if err != nil {
		t.Fatalf("decode json payload: %v", err)
	}
	if !bytes.Equal(gotJSON, rawJSON) {
		t.Fatalf("json bytes mismatch: got %q, want %q", gotJSON, rawJSON)
	}

	// Arbitrary binary payload including NUL and non-UTF8 bytes.
	rawBin := []byte{0x00, 0xff, 0x10, 0x80, 0xde, 0xad, 0xbe, 0xef}
	evBin := domain.Event{
		EventID:     "evt_2",
		Channel:     "@alice/bin",
		PublishedAt: time.Now().UTC(),
		ContentType: "application/octet-stream",
		Payload:     rawBin,
	}
	wireBin, err := MarshalEventEnvelope(evBin)
	if err != nil {
		t.Fatalf("marshal binary envelope: %v", err)
	}
	var decodedBin Envelope
	if err := json.Unmarshal(wireBin, &decodedBin); err != nil {
		t.Fatalf("unmarshal binary envelope: %v", err)
	}
	if decodedBin.PayloadEncoding != "base64" {
		t.Fatalf("expected base64 encoding, got %q", decodedBin.PayloadEncoding)
	}
	gotBin, err := DecodeEnvelopePayload(decodedBin)
	if err != nil {
		t.Fatalf("decode binary payload: %v", err)
	}
	if !bytes.Equal(gotBin, rawBin) {
		t.Fatalf("binary bytes mismatch: got %x, want %x", gotBin, rawBin)
	}
}

func TestHMACSigningAndVerification(t *testing.T) {
	secret := []byte("super-secret-webhook-key")
	body := []byte(`{"envelope_version":1,"event_id":"evt_1"}`)
	now := time.Unix(1700000000, 0).UTC()
	tsStr := strconv.FormatInt(now.Unix(), 10)
	sig := Sign(secret, now.Unix(), body)

	if err := VerifySignature(secret, tsStr, sig, body, 5*time.Minute, now.Add(30*time.Second)); err != nil {
		t.Fatalf("expected valid signature, got: %v", err)
	}
	if err := VerifySignature([]byte("wrong-secret"), tsStr, sig, body, 5*time.Minute, now); !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("expected ErrInvalidSignature for wrong secret, got: %v", err)
	}
	if err := VerifySignature(secret, tsStr, sig, append(body, '!'), 5*time.Minute, now); !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("expected ErrInvalidSignature for tampered body, got: %v", err)
	}
	if err := VerifySignature(secret, tsStr, sig, body, 5*time.Minute, now.Add(6*time.Minute)); !errors.Is(err, ErrExpiredTimestamp) {
		t.Fatalf("expected ErrExpiredTimestamp for stale timestamp, got: %v", err)
	}
}

type fakeResolver struct {
	ips []netip.Addr
}

func (f fakeResolver) LookupNetIP(_ context.Context, _, _ string) ([]netip.Addr, error) {
	return f.ips, nil
}

func TestSSRFDefenses(t *testing.T) {
	blocked := []string{
		"127.0.0.1",
		"10.0.0.5",
		"172.16.1.2",
		"192.168.1.1",
		"169.254.169.254",
		"100.64.0.1",
		"0.0.0.0",
		"::1",
		"fe80::1",
		"fc00::1",
		"fd00:ec2::254",
		"::ffff:127.0.0.1",
		"::ffff:169.254.169.254",
	}
	for _, s := range blocked {
		ip := netip.MustParseAddr(s)
		if !IsBlockedIP(ip) {
			t.Fatalf("expected %s to be blocked by SSRF policy", s)
		}
	}

	allowed := []string{"93.184.216.34", "1.1.1.1", "2606:2800:220:1:248:1893:25c8:1946"}
	for _, s := range allowed {
		ip := netip.MustParseAddr(s)
		if IsBlockedIP(ip) {
			t.Fatalf("expected public IP %s to be allowed", s)
		}
	}

	// Enforce HTTPS by default.
	if _, err := ValidateEndpointURL("http://example.com/hook", false); !errors.Is(err, domain.ErrInvalidEndpoint) {
		t.Fatalf("expected http:// to be rejected when allowInsecureHTTP=false, got: %v", err)
	}

	// DNS rebinding defense: hostname resolves to loopback at connect time.
	cfg := config.DefaultConfig().Webhooks
	cfg.AllowInsecureHTTP = true
	cfg.AllowPrivateDestinations = false
	adapter := NewWebhookAdapter(cfg, fakeResolver{ips: []netip.Addr{netip.MustParseAddr("127.0.0.1")}})
	sub := domain.Subscription{
		ID:           "sub_1",
		Endpoint:     "http://rebind.evil.example/hook",
		SigningKeyID: "key_1",
	}
	res := adapter.Deliver(context.Background(), sub, []byte("secret"), domain.Event{
		EventID:     "evt_1",
		Channel:     "@alice/news",
		PublishedAt: time.Now().UTC(),
		ContentType: "application/json",
		Payload:     []byte(`{}`),
	})
	if res.Outcome != OutcomeSSRFBlocked || !errors.Is(res.Err, domain.ErrSSRFBlocked) {
		t.Fatalf("expected SSRF block on DNS rebinding to loopback, got outcome=%v err=%v", res.Outcome, res.Err)
	}

	// Redirects must not be followed by default.
	redirectHit := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirectHit = true
		w.WriteHeader(http.StatusOK)
	}))
	defer target.Close()

	redirector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusFound)
	}))
	defer redirector.Close()

	devCfg := config.DefaultConfig().Webhooks
	devCfg.AllowInsecureHTTP = true
	devCfg.AllowPrivateDestinations = true
	devAdapter := NewWebhookAdapter(devCfg, nil)
	sub.Endpoint = redirector.URL
	res = devAdapter.Deliver(context.Background(), sub, []byte("secret"), domain.Event{
		EventID:     "evt_2",
		Channel:     "@alice/news",
		PublishedAt: time.Now().UTC(),
		ContentType: "application/json",
		Payload:     []byte(`{}`),
	})
	if redirectHit {
		t.Fatalf("webhook client followed redirect, which must be disallowed by default")
	}
	if res.Outcome != OutcomePermanent4xx || res.HTTPStatus != http.StatusFound {
		t.Fatalf("expected 302 redirect to fail as permanent error, got outcome=%v status=%d", res.Outcome, res.HTTPStatus)
	}
}
