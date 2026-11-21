package delivery

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	HeaderTimestamp      = "X-OpenDotNews-Timestamp"
	HeaderEventID        = "X-OpenDotNews-Event-Id"
	HeaderSubscriptionID = "X-OpenDotNews-Subscription-Id"
	HeaderKeyID          = "X-OpenDotNews-Key-Id"
	HeaderSignature      = "X-OpenDotNews-Signature"
	HeaderEventKind      = "X-OpenDotNews-Event-Kind"

	EventKindEvent     = "event"
	EventKindChallenge = "challenge"

	DefaultMaxSignatureSkew = 5 * time.Minute
)

var (
	ErrMissingSignature   = errors.New("missing webhook signature or timestamp header")
	ErrInvalidSignature   = errors.New("invalid webhook signature")
	ErrExpiredTimestamp   = errors.New("webhook timestamp outside allowed skew")
)

// Sign computes "v1=<hex(HMAC-SHA256(secret, '<unix_ts>.<raw_body>'))>".
func Sign(secret []byte, timestamp int64, rawBody []byte) string {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(strconv.FormatInt(timestamp, 10)))
	mac.Write([]byte("."))
	mac.Write(rawBody)
	return "v1=" + hex.EncodeToString(mac.Sum(nil))
}

// VerifySignature validates a webhook request's HMAC-SHA256 signature and bounded timestamp skew.
func VerifySignature(secret []byte, timestampHeader, signatureHeader string, rawBody []byte, maxSkew time.Duration, now time.Time) error {
	if timestampHeader == "" || signatureHeader == "" {
		return ErrMissingSignature
	}
	ts, err := strconv.ParseInt(strings.TrimSpace(timestampHeader), 10, 64)
	if err != nil {
		return fmt.Errorf("%w: parse timestamp: %v", ErrExpiredTimestamp, err)
	}
	if maxSkew <= 0 {
		maxSkew = DefaultMaxSignatureSkew
	}
	if now.IsZero() {
		now = time.Now().UTC()
	}
	delta := now.Sub(time.Unix(ts, 0).UTC())
	if delta < 0 {
		delta = -delta
	}
	if delta > maxSkew {
		return fmt.Errorf("%w: skew %s exceeds %s", ErrExpiredTimestamp, delta, maxSkew)
	}

	if !strings.HasPrefix(signatureHeader, "v1=") {
		return ErrInvalidSignature
	}
	expected := Sign(secret, ts, rawBody)
	if !hmac.Equal([]byte(signatureHeader), []byte(expected)) {
		return ErrInvalidSignature
	}
	return nil
}
