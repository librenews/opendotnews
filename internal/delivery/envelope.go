package delivery

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/librenews/opendotnews/internal/domain"
)

const EnvelopeVersion = 1

// Envelope is the versioned transport wrapper sent to webhook receivers.
// The hub adds only transport metadata and never parses or mutates payload semantics.
type Envelope struct {
	EnvelopeVersion int             `json:"envelope_version"`
	EventID         string          `json:"event_id"`
	Channel         string          `json:"channel"`
	PublishedAt     string          `json:"published_at"`
	ContentType     string          `json:"content_type"`
	Payload         json.RawMessage `json:"payload,omitempty"`
	PayloadEncoding string          `json:"payload_encoding,omitempty"`
	PayloadBase64   string          `json:"payload_base64,omitempty"`
}

// ChallengeEnvelope is sent before webhook activation to verify endpoint ownership.
type ChallengeEnvelope struct {
	EnvelopeVersion int    `json:"envelope_version"`
	Type            string `json:"type"`
	SubscriptionID  string `json:"subscription_id"`
	Channel         string `json:"channel"`
	Challenge       string `json:"challenge"`
}

// ChallengeResponse is expected from a webhook receiver to complete verification.
type ChallengeResponse struct {
	Challenge string `json:"challenge"`
}

// MarshalEventEnvelope serializes an Event into the versioned transport envelope
// while preserving opaque payload bytes without semantic inspection.
func MarshalEventEnvelope(ev domain.Event) ([]byte, error) {
	env := Envelope{
		EnvelopeVersion: EnvelopeVersion,
		EventID:         ev.EventID,
		Channel:         ev.Channel,
		PublishedAt:     ev.PublishedAt.UTC().Format(time.RFC3339Nano),
		ContentType:     ev.ContentType,
	}

	if isJSONContentType(ev.ContentType) && len(ev.Payload) > 0 && json.Valid(ev.Payload) {
		env.Payload = json.RawMessage(ev.Payload)
	} else {
		env.PayloadEncoding = "base64"
		env.PayloadBase64 = base64.StdEncoding.EncodeToString(ev.Payload)
	}

	return json.Marshal(env)
}

// DecodeEnvelopePayload extracts the exact payload bytes from an Envelope.
func DecodeEnvelopePayload(env Envelope) ([]byte, error) {
	if env.PayloadEncoding == "base64" {
		b, err := base64.StdEncoding.DecodeString(env.PayloadBase64)
		if err != nil {
			return nil, fmt.Errorf("decode base64 payload: %w", err)
		}
		return b, nil
	}
	if len(env.Payload) > 0 {
		out := make([]byte, len(env.Payload))
		copy(out, env.Payload)
		return out, nil
	}
	return []byte{}, nil
}

func isJSONContentType(ct string) bool {
	ct = strings.ToLower(strings.TrimSpace(ct))
	if idx := strings.IndexByte(ct, ';'); idx >= 0 {
		ct = strings.TrimSpace(ct[:idx])
	}
	return ct == "application/json" || strings.HasSuffix(ct, "+json")
}
