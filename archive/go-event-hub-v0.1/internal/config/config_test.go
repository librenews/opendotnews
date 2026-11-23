package config

import "testing"

func TestAuthDisabledLoopbackGuard(t *testing.T) {
	cfg := DefaultConfig()
	cfg.ApplyDefaults()
	cfg.Auth.Mode = "disabled"
	cfg.Listen = "127.0.0.1:8080"
	if err := cfg.Validate(); err != nil {
		t.Fatalf("expected loopback disabled auth to be allowed: %v", err)
	}

	cfg.Listen = "0.0.0.0:8080"
	if err := cfg.Validate(); err == nil {
		t.Fatalf("expected non-loopback disabled auth to be rejected")
	}

	cfg.Auth.AllowUnsafeDisabledNonLoopback = true
	if err := cfg.Validate(); err != nil {
		t.Fatalf("expected explicit override to allow non-loopback disabled auth: %v", err)
	}
}

func TestExternalNATSRequiresURL(t *testing.T) {
	cfg := DefaultConfig()
	cfg.ApplyDefaults()
	cfg.NATS.Mode = "external"
	cfg.NATS.URL = ""
	if err := cfg.Validate(); err == nil {
		t.Fatalf("expected external nats without url to fail validation")
	}
	cfg.NATS.URL = "nats://127.0.0.1:4222"
	if err := cfg.Validate(); err != nil {
		t.Fatalf("expected valid external nats config: %v", err)
	}
}
