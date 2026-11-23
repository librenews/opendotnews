package opendotnews_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/librenews/opendotnews/internal/domain"
	"github.com/librenews/opendotnews/internal/embeddednats"
	"github.com/librenews/opendotnews/pkg/opendotnews"
)

type receivedEvent struct {
	Envelope opendotnews.Envelope
	Payload  []byte
	KeyID    string
	Headers  http.Header
}

type testReceiver struct {
	server *httptest.Server

	mu            sync.Mutex
	secrets       map[string]string // key_id -> secret (or "" fallback)
	fallbackKey   string
	failStatus    int
	failRemaining int
	delay         time.Duration
	rejectChal    bool
	events        []receivedEvent
	notify        chan receivedEvent
}

func newTestReceiver(t *testing.T) *testReceiver {
	t.Helper()
	r := &testReceiver{
		secrets: make(map[string]string),
		notify:  make(chan receivedEvent, 64),
	}
	r.server = httptest.NewServer(http.HandlerFunc(r.handle))
	t.Cleanup(r.server.Close)
	return r
}

func (r *testReceiver) URL() string { return r.server.URL }

func (r *testReceiver) SetSecret(keyID, sec string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.secrets[keyID] = sec
	r.fallbackKey = sec
}

func (r *testReceiver) SetFailure(status int, count int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.failStatus = status
	r.failRemaining = count // <0 means always fail
}

func (r *testReceiver) SetDelay(d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.delay = d
}

func (r *testReceiver) SetRejectChallenge(reject bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.rejectChal = reject
}

func (r *testReceiver) Events() []receivedEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	cp := make([]receivedEvent, len(r.events))
	copy(cp, r.events)
	return cp
}

func (r *testReceiver) WaitEvent(t *testing.T, timeout time.Duration) receivedEvent {
	t.Helper()
	select {
	case ev := <-r.notify:
		return ev
	case <-time.After(timeout):
		t.Fatalf("timed out after %s waiting for webhook event", timeout)
		return receivedEvent{}
	}
}

func (r *testReceiver) handle(w http.ResponseWriter, req *http.Request) {
	body, _ := io.ReadAll(req.Body)

	r.mu.Lock()
	delay := r.delay
	rejectChal := r.rejectChal
	failStatus := 0
	if req.Header.Get(opendotnews.HeaderEventKind) != "challenge" && r.failStatus != 0 && r.failRemaining != 0 {
		failStatus = r.failStatus
		if r.failRemaining > 0 {
			r.failRemaining--
		}
	}
	r.mu.Unlock()

	if delay > 0 {
		time.Sleep(delay)
	}

	if req.Header.Get(opendotnews.HeaderEventKind) == "challenge" {
		if rejectChal {
			http.Error(w, "challenge rejected", http.StatusForbidden)
			return
		}
		var ch opendotnews.ChallengeEnvelope
		_ = json.Unmarshal(body, &ch)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(opendotnews.ChallengeResponse{Challenge: ch.Challenge})
		return
	}

	r.mu.Lock()
	keyID := req.Header.Get(opendotnews.HeaderKeyID)
	sec := r.secrets[keyID]
	if sec == "" {
		sec = r.fallbackKey
	}
	r.mu.Unlock()

	if sec != "" {
		if err := opendotnews.VerifyWebhookSignature(
			[]byte(sec),
			req.Header.Get(opendotnews.HeaderTimestamp),
			req.Header.Get(opendotnews.HeaderSignature),
			body,
			5*time.Minute,
		); err != nil {
			http.Error(w, "bad signature", http.StatusUnauthorized)
			return
		}
	}

	if failStatus != 0 {
		http.Error(w, fmt.Sprintf("simulated %d", failStatus), failStatus)
		return
	}

	var env opendotnews.Envelope
	if err := json.Unmarshal(body, &env); err != nil {
		http.Error(w, "bad envelope", http.StatusBadRequest)
		return
	}
	payload, err := opendotnews.DecodeEnvelopePayload(env)
	if err != nil {
		http.Error(w, "bad payload", http.StatusBadRequest)
		return
	}

	ev := receivedEvent{
		Envelope: env,
		Payload:  payload,
		KeyID:    keyID,
		Headers:  req.Header.Clone(),
	}
	r.mu.Lock()
	r.events = append(r.events, ev)
	r.mu.Unlock()
	select {
	case r.notify <- ev:
	default:
	}
	w.WriteHeader(http.StatusOK)
}

func startTestHub(t *testing.T, dataDir string, customize func(*opendotnews.Config)) *opendotnews.Hub {
	t.Helper()
	cfg := opendotnews.DefaultConfig()
	cfg.Listen = "127.0.0.1:0"
	cfg.DataDir = dataDir
	cfg.NATS.StoreDir = filepath.Join(dataDir, "jetstream")
	cfg.Auth.AdminToken = "test-admin-token"
	cfg.Webhooks.AllowInsecureHTTP = true
	cfg.Webhooks.AllowPrivateDestinations = true
	cfg.Webhooks.InitialBackoff = 40 * time.Millisecond
	cfg.Webhooks.MaxBackoff = 150 * time.Millisecond
	cfg.Webhooks.Timeout = 2 * time.Second
	cfg.Webhooks.AckWait = 2 * time.Second
	if customize != nil {
		customize(&cfg)
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	hub, err := opendotnews.New(cfg, opendotnews.Dependencies{Logger: logger})
	if err != nil {
		t.Fatalf("new hub: %v", err)
	}
	if err := hub.Start(context.Background()); err != nil {
		t.Fatalf("start hub: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = hub.Shutdown(ctx)
	})
	return hub
}

func principalFor(accountID string, scopes ...string) opendotnews.Principal {
	m := make(map[string]bool, len(scopes))
	for _, s := range scopes {
		m[s] = true
	}
	return opendotnews.Principal{AccountID: accountID, Scopes: m}
}

func TestFunctionalPubSubFanoutAndACLs(t *testing.T) {
	ctx := context.Background()
	hub := startTestHub(t, t.TempDir(), nil)

	alice, err := hub.CreateAccount(ctx, "alice")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := hub.CreateAccount(ctx, "bob")
	if err != nil {
		t.Fatal(err)
	}
	carol, err := hub.CreateAccount(ctx, "carol")
	if err != nil {
		t.Fatal(err)
	}

	// Concurrent namespace claim collisions: exactly one succeeds.
	var winners atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			name := "Alice"
			if idx%2 == 0 {
				name = "alice"
			}
			if _, err := hub.ClaimNamespace(ctx, alice.ID, name); err == nil {
				winners.Add(1)
			}
		}(i)
	}
	wg.Wait()
	if winners.Load() != 1 {
		t.Fatalf("expected exactly 1 namespace claim winner, got %d", winners.Load())
	}
	if _, err := hub.ClaimNamespace(ctx, bob.ID, "bob"); err != nil {
		t.Fatal(err)
	}

	aliceP := principalFor(alice.ID, opendotnews.ScopeEventsPublish, opendotnews.ScopeSubscriptionsWrite)
	bobP := principalFor(bob.ID, opendotnews.ScopeEventsPublish, opendotnews.ScopeSubscriptionsWrite)
	carolP := principalFor(carol.ID, opendotnews.ScopeSubscriptionsWrite)

	// Ownership ACL: Alice cannot publish to @bob/news.
	if _, err := hub.Publish(ctx, aliceP, opendotnews.PublishInput{
		Channel:     "@bob/news",
		ContentType: "application/json",
		Payload:     []byte(`{"forbidden":true}`),
	}); !errors.Is(err, domain.ErrForbidden) {
		t.Fatalf("expected ErrForbidden publishing to another namespace, got: %v", err)
	}

	// Unsupported delivery mode returns explicit capability error.
	if _, err := hub.Subscribe(ctx, bobP, opendotnews.SubscribeInput{
		Channel:      "@alice/news",
		DeliveryMode: opendotnews.DeliveryModeMCP,
		Endpoint:     "https://example.com",
	}); !errors.Is(err, domain.ErrUnsupportedDeliveryMode) {
		t.Fatalf("expected ErrUnsupportedDeliveryMode, got: %v", err)
	}

	// Two independent webhook receivers (Bob & Carol) subscribe to @alice/news.
	bobRecv := newTestReceiver(t)
	carolRecv := newTestReceiver(t)

	bobSub, err := hub.Subscribe(ctx, bobP, opendotnews.SubscribeInput{
		Channel:      "@alice/news",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     bobRecv.URL(),
	})
	if err != nil {
		t.Fatalf("bob subscribe: %v", err)
	}
	bobRecv.SetSecret(bobSub.SigningKeyID, bobSub.SigningSecret)

	// Duplicate subscribe with same endpoint is idempotent and returns existing ID.
	bobSubDup, err := hub.Subscribe(ctx, bobP, opendotnews.SubscribeInput{
		Channel:      "@alice/news",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     bobRecv.URL(),
	})
	if err != nil {
		t.Fatalf("bob duplicate subscribe: %v", err)
	}
	if bobSubDup.SubscriptionID != bobSub.SubscriptionID || !bobSubDup.Existing {
		t.Fatalf("expected idempotent duplicate subscribe to return same ID")
	}

	// Changing destination without replace=true fails with conflict.
	if _, err := hub.Subscribe(ctx, bobP, opendotnews.SubscribeInput{
		Channel:      "@alice/news",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     carolRecv.URL(),
	}); !errors.Is(err, domain.ErrSubscriptionConflict) {
		t.Fatalf("expected ErrSubscriptionConflict on destination swap without replace, got: %v", err)
	}

	carolSub, err := hub.Subscribe(ctx, carolP, opendotnews.SubscribeInput{
		Channel:      "@alice/news",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     carolRecv.URL(),
	})
	if err != nil {
		t.Fatalf("carol subscribe: %v", err)
	}
	carolRecv.SetSecret(carolSub.SigningKeyID, carolSub.SigningSecret)

	// Publish JSON and arbitrary binary payloads; BOTH Bob and Carol must receive BOTH byte-for-byte.
	jsonPayload := []byte(`{"url":"https://example.org/agenda/42","seq":1}`)
	binPayload := []byte{0x00, 0x01, 0xfe, 0xff, 'o', 'd', 'n'}

	pub1, err := hub.Publish(ctx, aliceP, opendotnews.PublishInput{
		Channel:        "@alice/news",
		ContentType:    "application/json",
		Payload:        jsonPayload,
		IdempotencyKey: "idem-key-1",
	})
	if err != nil {
		t.Fatalf("publish json: %v", err)
	}
	// Duplicate publish with same idempotency_key is deduplicated by JetStream.
	if _, err := hub.Publish(ctx, aliceP, opendotnews.PublishInput{
		Channel:        "@alice/news",
		ContentType:    "application/json",
		Payload:        jsonPayload,
		IdempotencyKey: "idem-key-1",
	}); err != nil {
		t.Fatalf("duplicate publish: %v", err)
	}

	pub2, err := hub.Publish(ctx, aliceP, opendotnews.PublishInput{
		Channel:     "@alice/news",
		ContentType: "application/octet-stream",
		Payload:     binPayload,
	})
	if err != nil {
		t.Fatalf("publish binary: %v", err)
	}

	for name, recv := range map[string]*testReceiver{"bob": bobRecv, "carol": carolRecv} {
		ev1 := recv.WaitEvent(t, 5*time.Second)
		ev2 := recv.WaitEvent(t, 5*time.Second)
		if ev1.Envelope.EventID != pub1.EventID || !bytes.Equal(ev1.Payload, jsonPayload) {
			t.Fatalf("%s event 1 mismatch: id=%s payload=%q", name, ev1.Envelope.EventID, ev1.Payload)
		}
		if ev2.Envelope.EventID != pub2.EventID || !bytes.Equal(ev2.Payload, binPayload) {
			t.Fatalf("%s event 2 mismatch: id=%s payload=%x", name, ev2.Envelope.EventID, ev2.Payload)
		}
	}

	// Bob cannot unsubscribe Carol's subscription.
	if _, err := hub.Unsubscribe(ctx, bobP, opendotnews.UnsubscribeInput{SubscriptionID: carolSub.SubscriptionID}); !errors.Is(err, domain.ErrForbidden) {
		t.Fatalf("expected ErrForbidden unsubscribing another user's sub, got: %v", err)
	}

	// Unsubscribe Bob (and verify idempotent second call) -> Bob receives no more events, Carol still does.
	if _, err := hub.Unsubscribe(ctx, bobP, opendotnews.UnsubscribeInput{SubscriptionID: bobSub.SubscriptionID}); err != nil {
		t.Fatalf("unsubscribe bob: %v", err)
	}
	if _, err := hub.Unsubscribe(ctx, bobP, opendotnews.UnsubscribeInput{SubscriptionID: bobSub.SubscriptionID}); err != nil {
		t.Fatalf("idempotent unsubscribe bob: %v", err)
	}

	pub3, err := hub.Publish(ctx, aliceP, opendotnews.PublishInput{
		Channel:     "@alice/news",
		ContentType: "application/json",
		Payload:     []byte(`{"after_unsub":true}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	ev3 := carolRecv.WaitEvent(t, 5*time.Second)
	if ev3.Envelope.EventID != pub3.EventID {
		t.Fatalf("expected carol to receive pub3 %s, got %s", pub3.EventID, ev3.Envelope.EventID)
	}
	time.Sleep(250 * time.Millisecond)
	if len(bobRecv.Events()) != 2 {
		t.Fatalf("expected bob to receive no events after unsubscribe, got %d", len(bobRecv.Events()))
	}
}

func TestReliabilityOutageReplayAndHubRestart(t *testing.T) {
	ctx := context.Background()
	dataDir := t.TempDir()

	hub1 := startTestHub(t, dataDir, nil)
	alice, _ := hub1.CreateAccount(ctx, "alice")
	bob, _ := hub1.CreateAccount(ctx, "bob")
	if _, err := hub1.ClaimNamespace(ctx, alice.ID, "alice"); err != nil {
		t.Fatal(err)
	}
	aliceP := principalFor(alice.ID, opendotnews.ScopeEventsPublish)
	bobP := principalFor(bob.ID, opendotnews.ScopeSubscriptionsWrite)

	recv := newTestReceiver(t)
	subRes, err := hub1.Subscribe(ctx, bobP, opendotnews.SubscribeInput{
		Channel:      "@alice/updates",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     recv.URL(),
	})
	if err != nil {
		t.Fatal(err)
	}
	recv.SetSecret(subRes.SigningKeyID, subRes.SigningSecret)

	// 1. Simulate temporary receiver outage (503 for 2 attempts), then recover.
	recv.SetFailure(http.StatusServiceUnavailable, 2)
	p1, err := hub1.Publish(ctx, aliceP, opendotnews.PublishInput{
		Channel:     "@alice/updates",
		ContentType: "application/json",
		Payload:     []byte(`{"n":1}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	ev1 := recv.WaitEvent(t, 5*time.Second)
	if ev1.Envelope.EventID != p1.EventID {
		t.Fatalf("expected replay of p1, got %s", ev1.Envelope.EventID)
	}

	// 2. Make receiver continuously fail (503), publish 2 events, then shut down ENTIRE HUB.
	recv.SetFailure(http.StatusServiceUnavailable, -1)
	p2, err := hub1.Publish(ctx, aliceP, opendotnews.PublishInput{
		Channel:     "@alice/updates",
		ContentType: "application/json",
		Payload:     []byte(`{"n":2}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	p3, err := hub1.Publish(ctx, aliceP, opendotnews.PublishInput{
		Channel:     "@alice/updates",
		ContentType: "application/json",
		Payload:     []byte(`{"n":3}`),
	})
	if err != nil {
		t.Fatal(err)
	}

	shutdownCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	if err := hub1.Shutdown(shutdownCtx); err != nil {
		t.Fatalf("shutdown hub1: %v", err)
	}
	cancel()

	// Bring receiver back healthy, start a brand-new Hub pointing at the same dataDir.
	recv.SetFailure(0, 0)
	_ = startTestHub(t, dataDir, nil)

	ev2 := recv.WaitEvent(t, 5*time.Second)
	ev3 := recv.WaitEvent(t, 5*time.Second)
	gotIDs := map[string]bool{ev2.Envelope.EventID: true, ev3.Envelope.EventID: true}
	if !gotIDs[p2.EventID] || !gotIDs[p3.EventID] {
		t.Fatalf("expected both p2 (%s) and p3 (%s) after hub restart, got %s and %s", p2.EventID, p3.EventID, ev2.Envelope.EventID, ev3.Envelope.EventID)
	}
}

func TestReliability4xxPauseRetryExhaustionAndAdminRetry(t *testing.T) {
	ctx := context.Background()
	hub := startTestHub(t, t.TempDir(), func(c *opendotnews.Config) {
		c.Webhooks.MaxAttempts = 3
		c.Webhooks.InitialBackoff = 25 * time.Millisecond
		c.Webhooks.MaxBackoff = 60 * time.Millisecond
	})

	alice, _ := hub.CreateAccount(ctx, "alice")
	bob, _ := hub.CreateAccount(ctx, "bob")
	_, _ = hub.ClaimNamespace(ctx, alice.ID, "alice")
	aliceP := principalFor(alice.ID, opendotnews.ScopeEventsPublish)
	bobP := principalFor(bob.ID, opendotnews.ScopeSubscriptionsWrite)

	recv := newTestReceiver(t)
	sub, err := hub.Subscribe(ctx, bobP, opendotnews.SubscribeInput{
		Channel:      "@alice/alerts",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     recv.URL(),
	})
	if err != nil {
		t.Fatal(err)
	}
	recv.SetSecret(sub.SigningKeyID, sub.SigningSecret)

	// Return persistent 401 -> subscription should pause as unhealthy with http_4xx failure record.
	recv.SetFailure(http.StatusUnauthorized, -1)
	pub, err := hub.Publish(ctx, aliceP, opendotnews.PublishInput{
		Channel:     "@alice/alerts",
		ContentType: "application/json",
		Payload:     []byte(`{"alert":1}`),
	})
	if err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(5 * time.Second)
	var failures []opendotnews.DeliveryFailure
	for time.Now().Before(deadline) {
		failures, _ = hub.ListDeliveryFailures(ctx, sub.SubscriptionID, 10)
		if len(failures) > 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if len(failures) == 0 || failures[0].FailureCategory != domain.FailureCategoryHTTP4xx {
		t.Fatalf("expected http_4xx failure diagnostic, got: %+v", failures)
	}

	// Fix receiver and invoke admin retry -> paused event is delivered!
	recv.SetFailure(0, 0)
	if _, err := hub.RetrySubscription(ctx, sub.SubscriptionID); err != nil {
		t.Fatalf("retry subscription: %v", err)
	}
	ev := recv.WaitEvent(t, 5*time.Second)
	if ev.Envelope.EventID != pub.EventID {
		t.Fatalf("expected retried event %s, got %s", pub.EventID, ev.Envelope.EventID)
	}
}

func TestReliabilitySlowReceiverIsolationAndRetentionGap(t *testing.T) {
	ctx := context.Background()
	hub := startTestHub(t, t.TempDir(), func(c *opendotnews.Config) {
		c.Retention.MaxMessages = 2 // Small cap to trigger deterministic retention expiration
		c.Webhooks.MaxAttempts = 10
		c.Webhooks.InitialBackoff = 150 * time.Millisecond
		c.Webhooks.MaxBackoff = 200 * time.Millisecond
	})

	alice, _ := hub.CreateAccount(ctx, "alice")
	fastUser, _ := hub.CreateAccount(ctx, "fast")
	slowUser, _ := hub.CreateAccount(ctx, "slow")
	_, _ = hub.ClaimNamespace(ctx, alice.ID, "alice")

	aliceP := principalFor(alice.ID, opendotnews.ScopeEventsPublish)
	fastP := principalFor(fastUser.ID, opendotnews.ScopeSubscriptionsWrite)
	slowP := principalFor(slowUser.ID, opendotnews.ScopeSubscriptionsWrite)

	fastRecv := newTestReceiver(t)
	slowRecv := newTestReceiver(t)

	fastSub, err := hub.Subscribe(ctx, fastP, opendotnews.SubscribeInput{
		Channel:      "@alice/stream",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     fastRecv.URL(),
	})
	if err != nil {
		t.Fatal(err)
	}
	fastRecv.SetSecret(fastSub.SigningKeyID, fastSub.SigningSecret)

	slowSub, err := hub.Subscribe(ctx, slowP, opendotnews.SubscribeInput{
		Channel:      "@alice/stream",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     slowRecv.URL(),
	})
	if err != nil {
		t.Fatal(err)
	}
	slowRecv.SetSecret(slowSub.SigningKeyID, slowSub.SigningSecret)

	// Slow receiver delays 1.5s and fails; fast receiver must receive immediately (<500ms).
	slowRecv.SetDelay(1500 * time.Millisecond)
	slowRecv.SetFailure(http.StatusInternalServerError, -1)

	start := time.Now()
	_, err = hub.Publish(ctx, aliceP, opendotnews.PublishInput{
		Channel:     "@alice/stream",
		ContentType: "application/json",
		Payload:     []byte(`{"seq":1}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	fastRecv.WaitEvent(t, 1*time.Second)
	if elapsed := time.Since(start); elapsed > 800*time.Millisecond {
		t.Fatalf("fast subscriber was blocked by slow subscriber: elapsed=%s", elapsed)
	}

	// Publish 3 more events so event 1 is evicted by MaxMessages=2 while slowSub is still failing on it.
	for i := 2; i <= 4; i++ {
		_, err = hub.Publish(ctx, aliceP, opendotnews.PublishInput{
			Channel:     "@alice/stream",
			ContentType: "application/json",
			Payload:     []byte(fmt.Sprintf(`{"seq":%d}`, i)),
		})
		if err != nil {
			t.Fatal(err)
		}
	}

	// Now let slowRecv recover quickly; worker should detect that seq 1 was evicted by retention!
	slowRecv.SetDelay(0)
	slowRecv.SetFailure(0, 0)

	deadline := time.Now().Add(5 * time.Second)
	foundGap := false
	for time.Now().Before(deadline) {
		failures, _ := hub.ListDeliveryFailures(ctx, slowSub.SubscriptionID, 10)
		for _, f := range failures {
			if f.FailureCategory == domain.FailureCategoryRetentionGap {
				foundGap = true
				break
			}
		}
		if foundGap {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !foundGap {
		t.Fatalf("expected retention_gap failure diagnostic when events expired before delivery")
	}
}

func TestExternalNATSModeAndBrokerOutage(t *testing.T) {
	ctx := context.Background()

	// Spin up an independent NATS JetStream server to exercise nats.mode=external.
	extNATS, err := embeddednats.Start(ctx, embeddednats.Options{
		Host:     "127.0.0.1",
		Port:     -1,
		StoreDir: filepath.Join(t.TempDir(), "ext-js"),
	})
	if err != nil {
		t.Fatalf("start external nats: %v", err)
	}
	defer extNATS.Shutdown()

	hub := startTestHub(t, t.TempDir(), func(c *opendotnews.Config) {
		c.NATS.Mode = "external"
		c.NATS.URL = extNATS.ClientURL()
		c.NATS.StoreDir = ""
	})

	alice, _ := hub.CreateAccount(ctx, "alice")
	bob, _ := hub.CreateAccount(ctx, "bob")
	_, _ = hub.ClaimNamespace(ctx, alice.ID, "alice")
	aliceP := principalFor(alice.ID, opendotnews.ScopeEventsPublish)
	bobP := principalFor(bob.ID, opendotnews.ScopeSubscriptionsWrite)

	recv := newTestReceiver(t)
	sub, err := hub.Subscribe(ctx, bobP, opendotnews.SubscribeInput{
		Channel:      "@alice/ext",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     recv.URL(),
	})
	if err != nil {
		t.Fatalf("external nats subscribe: %v", err)
	}
	recv.SetSecret(sub.SigningKeyID, sub.SigningSecret)

	pub, err := hub.Publish(ctx, aliceP, opendotnews.PublishInput{
		Channel:     "@alice/ext",
		ContentType: "application/json",
		Payload:     []byte(`{"external":true}`),
	})
	if err != nil {
		t.Fatalf("external nats publish: %v", err)
	}
	ev := recv.WaitEvent(t, 5*time.Second)
	if ev.Envelope.EventID != pub.EventID {
		t.Fatalf("expected %s, got %s", pub.EventID, ev.Envelope.EventID)
	}

	// Shut down external NATS -> publish MUST fail (never return false success).
	extNATS.Shutdown()
	pubCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if _, err := hub.Publish(pubCtx, aliceP, opendotnews.PublishInput{
		Channel:     "@alice/ext",
		ContentType: "application/json",
		Payload:     []byte(`{"during_outage":true}`),
	}); !errors.Is(err, domain.ErrBrokerUnavailable) {
		t.Fatalf("expected ErrBrokerUnavailable during broker outage, got: %v", err)
	}
}

func TestSecurityHTTPAuthLimitsAndChallenge(t *testing.T) {
	ctx := context.Background()
	hub := startTestHub(t, t.TempDir(), func(c *opendotnews.Config) {
		c.Retention.MaxPayloadBytes = 64
		c.Limits.MaxSubscriptionsPerAccount = 1
	})

	alice, _ := hub.CreateAccount(ctx, "alice")
	_, _ = hub.ClaimNamespace(ctx, alice.ID, "alice")
	aliceTok, err := hub.CreateLocalToken(ctx, alice.ID, []string{
		opendotnews.ScopeEventsPublish,
		opendotnews.ScopeSubscriptionsWrite,
		opendotnews.ScopeSubscriptionsRead,
	}, false)
	if err != nil {
		t.Fatal(err)
	}

	baseURL := "http://" + hub.Addr()

	// Health & readiness probes succeed.
	for _, ep := range []string{"/healthz", "/readyz"} {
		resp, err := http.Get(baseURL + ep)
		if err != nil || resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s failed: resp=%v err=%v", ep, resp, err)
		}
		resp.Body.Close()
	}

	// Forged token rejected with 401.
	req, _ := http.NewRequest(http.MethodPost, baseURL+"/v1/publish", bytes.NewBufferString(`{"channel":"@alice/news","payload":{"a":1}}`))
	req.Header.Set("Authorization", "Bearer forged-token")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 for forged token, got %d", resp.StatusCode)
	}

	// Oversize payload rejected with 413.
	big := fmt.Sprintf(`{"channel":"@alice/news","payload":{"x":%q}}`, string(bytes.Repeat([]byte("a"), 100)))
	req, _ = http.NewRequest(http.MethodPost, baseURL+"/v1/publish", bytes.NewBufferString(big))
	req.Header.Set("Authorization", "Bearer "+aliceTok)
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413 for oversize payload, got %d", resp.StatusCode)
	}

	// Webhook challenge failure prevents subscription activation.
	badRecv := newTestReceiver(t)
	badRecv.SetRejectChallenge(true)
	aliceP := principalFor(alice.ID, opendotnews.ScopeSubscriptionsWrite)
	if _, err := hub.Subscribe(ctx, aliceP, opendotnews.SubscribeInput{
		Channel:      "@alice/news",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     badRecv.URL(),
	}); !errors.Is(err, domain.ErrWebhookChallengeFailed) {
		t.Fatalf("expected ErrWebhookChallengeFailed, got: %v", err)
	}

	// Subscription quota enforced (max 1).
	goodRecv := newTestReceiver(t)
	if _, err := hub.Subscribe(ctx, aliceP, opendotnews.SubscribeInput{
		Channel:      "@alice/ch1",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     goodRecv.URL(),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := hub.Subscribe(ctx, aliceP, opendotnews.SubscribeInput{
		Channel:      "@alice/ch2",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     goodRecv.URL(),
	}); !errors.Is(err, domain.ErrQuotaExceeded) {
		t.Fatalf("expected ErrQuotaExceeded on 2nd subscription, got: %v", err)
	}

	// Disabling account revokes its tokens immediately.
	if err := hub.DisableAccount(ctx, alice.ID); err != nil {
		t.Fatal(err)
	}
	req, _ = http.NewRequest(http.MethodPost, baseURL+"/v1/publish", bytes.NewBufferString(`{"channel":"@alice/news","payload":{"a":1}}`))
	req.Header.Set("Authorization", "Bearer "+aliceTok)
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized && resp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 401/403 after account disabled, got %d", resp.StatusCode)
	}
}
