package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/librenews/opendotnews/pkg/opendotnews"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:9090", "listen address")
	secret := flag.String("secret", "", "per-subscription HMAC signing secret (optional during initial challenge)")
	failStatus := flag.Int("fail-status", 0, "if non-zero, respond with this HTTP status to simulate receiver failures")
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("POST /webhook", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			http.Error(w, "read body failed", http.StatusBadRequest)
			return
		}

		kind := r.Header.Get(opendotnews.HeaderEventKind)
		if kind == "challenge" {
			var ch opendotnews.ChallengeEnvelope
			if err := json.Unmarshal(body, &ch); err != nil {
				http.Error(w, "bad challenge", http.StatusBadRequest)
				return
			}
			log.Printf("verified webhook challenge subscription=%s channel=%s", ch.SubscriptionID, ch.Channel)
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(opendotnews.ChallengeResponse{Challenge: ch.Challenge})
			return
		}

		if *secret != "" {
			err := opendotnews.VerifyWebhookSignature(
				[]byte(*secret),
				r.Header.Get(opendotnews.HeaderTimestamp),
				r.Header.Get(opendotnews.HeaderSignature),
				body,
				5*time.Minute,
			)
			if err != nil {
				log.Printf("rejected event: invalid signature: %v", err)
				http.Error(w, "invalid signature", http.StatusUnauthorized)
				return
			}
		}

		if *failStatus != 0 {
			http.Error(w, fmt.Sprintf("simulated HTTP %d", *failStatus), *failStatus)
			return
		}

		var env opendotnews.Envelope
		if err := json.Unmarshal(body, &env); err != nil {
			http.Error(w, "invalid envelope", http.StatusBadRequest)
			return
		}
		payload, err := opendotnews.DecodeEnvelopePayload(env)
		if err != nil {
			http.Error(w, "decode payload failed", http.StatusBadRequest)
			return
		}

		log.Printf("received event id=%s channel=%s content_type=%s bytes=%d payload=%q",
			env.EventID, env.Channel, env.ContentType, len(payload), string(payload))
		w.WriteHeader(http.StatusOK)
	})

	log.Printf("reference webhook receiver listening on http://%s/webhook", *listen)
	if err := http.ListenAndServe(*listen, mux); err != nil {
		log.Fatal(err)
	}
}
