package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"time"

	"github.com/librenews/opendotnews/pkg/opendotnews"
)

func main() {
	ctx := context.Background()

	tmpDir, err := os.MkdirTemp("", "opendotnews-embedded-example-*")
	if err != nil {
		log.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	received := make(chan opendotnews.Envelope, 1)
	var subSecret string

	receiver := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.Header.Get(opendotnews.HeaderEventKind) == "challenge" {
			var ch opendotnews.ChallengeEnvelope
			_ = json.Unmarshal(body, &ch)
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(opendotnews.ChallengeResponse{Challenge: ch.Challenge})
			return
		}
		if err := opendotnews.VerifyWebhookSignature(
			[]byte(subSecret),
			r.Header.Get(opendotnews.HeaderTimestamp),
			r.Header.Get(opendotnews.HeaderSignature),
			body,
			5*time.Minute,
		); err != nil {
			http.Error(w, "bad signature", http.StatusUnauthorized)
			return
		}
		var env opendotnews.Envelope
		_ = json.Unmarshal(body, &env)
		received <- env
		w.WriteHeader(http.StatusOK)
	}))
	defer receiver.Close()

	cfg := opendotnews.DefaultConfig()
	cfg.Listen = "127.0.0.1:0"
	cfg.DataDir = tmpDir
	cfg.NATS.StoreDir = filepath.Join(tmpDir, "jetstream")
	cfg.Webhooks.AllowInsecureHTTP = true
	cfg.Webhooks.AllowPrivateDestinations = true

	hub, err := opendotnews.New(cfg, opendotnews.Dependencies{})
	if err != nil {
		log.Fatal(err)
	}
	if err := hub.Start(ctx); err != nil {
		log.Fatal(err)
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = hub.Shutdown(shutdownCtx)
	}()

	alice, err := hub.CreateAccount(ctx, "alice")
	if err != nil {
		log.Fatal(err)
	}
	bob, err := hub.CreateAccount(ctx, "bob")
	if err != nil {
		log.Fatal(err)
	}
	if _, err := hub.ClaimNamespace(ctx, alice.ID, "alice"); err != nil {
		log.Fatal(err)
	}

	bobPrincipal := opendotnews.Principal{
		AccountID: bob.ID,
		Scopes:    map[string]bool{opendotnews.ScopeSubscriptionsWrite: true},
	}
	subRes, err := hub.Subscribe(ctx, bobPrincipal, opendotnews.SubscribeInput{
		Channel:      "@alice/news",
		DeliveryMode: opendotnews.DeliveryModeWebhook,
		Endpoint:     receiver.URL,
	})
	if err != nil {
		log.Fatal(err)
	}
	subSecret = subRes.SigningSecret

	alicePrincipal := opendotnews.Principal{
		AccountID: alice.ID,
		Scopes:    map[string]bool{opendotnews.ScopeEventsPublish: true},
	}
	pubRes, err := hub.Publish(ctx, alicePrincipal, opendotnews.PublishInput{
		Channel:     "@alice/news",
		ContentType: "application/json",
		Payload:     []byte(`{"headline":"Zoning board meets Tuesday"}`),
	})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("Published event %s to %s\n", pubRes.EventID, pubRes.Channel)

	select {
	case env := <-received:
		payload, _ := opendotnews.DecodeEnvelopePayload(env)
		fmt.Printf("Bob's receiver got verified event %s: %s\n", env.EventID, string(payload))
	case <-time.After(5 * time.Second):
		log.Fatal("timed out waiting for webhook delivery")
	}
}
