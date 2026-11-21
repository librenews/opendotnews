package domain

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/oklog/ulid/v2"
)

// NewID generates a URL- and NATS-safe opaque time-sortable identifier.
// If prefix is non-empty, the result is "<prefix>_<ULID>".
func NewID(prefix string) string {
	id := ulid.MustNew(ulid.Timestamp(time.Now().UTC()), rand.Reader).String()
	if prefix == "" {
		return id
	}
	return prefix + "_" + id
}

// NewSecretBytes returns n cryptographically random bytes.
func NewSecretBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return nil, fmt.Errorf("generate random bytes: %w", err)
	}
	return b, nil
}

// NewOpaqueToken returns a URL-safe random token with the given prefix.
func NewOpaqueToken(prefix string) (string, error) {
	b, err := NewSecretBytes(32)
	if err != nil {
		return "", err
	}
	enc := base64.RawURLEncoding.EncodeToString(b)
	if prefix == "" {
		return enc, nil
	}
	return prefix + "_" + enc, nil
}

// NewHexSecret returns a hex-encoded random secret of n bytes.
func NewHexSecret(n int) (string, error) {
	b, err := NewSecretBytes(n)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
