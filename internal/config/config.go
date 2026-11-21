package config

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	Listen    string          `yaml:"listen"`
	PublicURL string          `yaml:"public_url"`
	DataDir   string          `yaml:"data_dir"`
	Auth      AuthConfig      `yaml:"auth"`
	NATS      NATSConfig      `yaml:"nats"`
	Retention RetentionConfig `yaml:"retention"`
	Webhooks  WebhookConfig   `yaml:"webhooks"`
	Limits    LimitsConfig    `yaml:"limits"`
	Secrets   SecretConfig    `yaml:"secrets"`
}

type AuthConfig struct {
	Mode                           string             `yaml:"mode"` // "local", "oauth", "disabled"
	AdminToken                     string             `yaml:"admin_token"`
	LocalTokens                    []LocalTokenConfig `yaml:"local_tokens"`
	AllowUnsafeDisabledNonLoopback bool               `yaml:"allow_unsafe_disabled_non_loopback"`
}

type LocalTokenConfig struct {
	Token     string   `yaml:"token"`
	AccountID string   `yaml:"account_id"`
	Subject   string   `yaml:"subject"`
	Scopes    []string `yaml:"scopes"`
	IsAdmin   bool     `yaml:"is_admin"`
}

type NATSConfig struct {
	Mode       string `yaml:"mode"` // "embedded" or "external"
	StoreDir   string `yaml:"store_dir"`
	URL        string `yaml:"url"`
	Host       string `yaml:"host"` // embedded bind host (defaults to 127.0.0.1)
	Port       int    `yaml:"port"` // embedded bind port (-1 for random free port)
	StreamName string `yaml:"stream_name"`
}

type RetentionConfig struct {
	MaxAge            time.Duration `yaml:"max_age"`
	MaxPayloadBytes   int           `yaml:"max_payload_bytes"`
	MaxStorageBytes   int64         `yaml:"max_storage_bytes"`
	MaxMessages       int64         `yaml:"max_messages"`
	DuplicatesWindow  time.Duration `yaml:"duplicates_window"`
}

type WebhookConfig struct {
	Timeout                    time.Duration `yaml:"timeout"`
	MaxAttempts                int           `yaml:"max_attempts"`
	MaxRetryAge                time.Duration `yaml:"max_retry_age"`
	InitialBackoff             time.Duration `yaml:"initial_backoff"`
	MaxBackoff                 time.Duration `yaml:"max_backoff"`
	AckWait                    time.Duration `yaml:"ack_wait"`
	MaxInFlightPerSubscription int           `yaml:"max_in_flight_per_subscription"`
	MaxGlobalInFlight          int           `yaml:"max_global_in_flight"`
	AllowInsecureHTTP          bool          `yaml:"allow_insecure_http"`
	AllowPrivateDestinations   bool          `yaml:"allow_private_destinations"`
	SkipChallengeVerification  bool          `yaml:"skip_challenge_verification"`
}

type LimitsConfig struct {
	MaxSubscriptionsPerAccount int `yaml:"max_subscriptions_per_account"`
	MaxHTTPBodyBytes           int `yaml:"max_http_body_bytes"`
}

type SecretConfig struct {
	MasterKeyHex  string `yaml:"master_key_hex"`
	MasterKeyFile string `yaml:"master_key_file"`
}

// DefaultConfig returns safe, loopback-first defaults suitable for local single-binary operation.
func DefaultConfig() Config {
	return Config{
		Listen:    "127.0.0.1:8080",
		PublicURL: "http://127.0.0.1:8080",
		DataDir:   "./data",
		Auth: AuthConfig{
			Mode: "local",
		},
		NATS: NATSConfig{
			Mode:       "embedded",
			Host:       "127.0.0.1",
			Port:       -1,
			StreamName: "OPENDOTNEWS_EVENTS",
		},
		Retention: RetentionConfig{
			MaxAge:           168 * time.Hour,
			MaxPayloadBytes:  65536,
			MaxStorageBytes:  1073741824,
			MaxMessages:      -1,
			DuplicatesWindow: 2 * time.Minute,
		},
		Webhooks: WebhookConfig{
			Timeout:                    10 * time.Second,
			MaxAttempts:                12,
			MaxRetryAge:                24 * time.Hour,
			InitialBackoff:             1 * time.Second,
			MaxBackoff:                 5 * time.Minute,
			AckWait:                    30 * time.Second,
			MaxInFlightPerSubscription: 1,
			MaxGlobalInFlight:          64,
			AllowInsecureHTTP:          false,
			AllowPrivateDestinations:   false,
		},
		Limits: LimitsConfig{
			MaxSubscriptionsPerAccount: 100,
			MaxHTTPBodyBytes:           128 * 1024,
		},
	}
}

// LoadFile loads YAML configuration onto DefaultConfig and validates it.
func LoadFile(path string) (Config, error) {
	cfg := DefaultConfig()
	raw, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config %q: %w", path, err)
	}
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return Config{}, fmt.Errorf("parse config %q: %w", path, err)
	}
	cfg.ApplyDefaults()
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// ApplyDefaults fills derived paths and zero-valued fields without overwriting explicit choices.
func (c *Config) ApplyDefaults() {
	def := DefaultConfig()
	if c.Listen == "" {
		c.Listen = def.Listen
	}
	if c.DataDir == "" {
		c.DataDir = def.DataDir
	}
	if c.Auth.Mode == "" {
		c.Auth.Mode = def.Auth.Mode
	}
	if c.NATS.Mode == "" {
		c.NATS.Mode = def.NATS.Mode
	}
	if c.NATS.Host == "" {
		c.NATS.Host = def.NATS.Host
	}
	if c.NATS.Port == 0 {
		c.NATS.Port = -1
	}
	if c.NATS.StoreDir == "" {
		c.NATS.StoreDir = filepath.Join(c.DataDir, "jetstream")
	}
	if c.NATS.StreamName == "" {
		c.NATS.StreamName = def.NATS.StreamName
	}
	if c.Retention.MaxAge == 0 {
		c.Retention.MaxAge = def.Retention.MaxAge
	}
	if c.Retention.MaxPayloadBytes == 0 {
		c.Retention.MaxPayloadBytes = def.Retention.MaxPayloadBytes
	}
	if c.Retention.MaxStorageBytes == 0 {
		c.Retention.MaxStorageBytes = def.Retention.MaxStorageBytes
	}
	if c.Retention.DuplicatesWindow == 0 {
		c.Retention.DuplicatesWindow = def.Retention.DuplicatesWindow
	}
	if c.Webhooks.Timeout == 0 {
		c.Webhooks.Timeout = def.Webhooks.Timeout
	}
	if c.Webhooks.MaxAttempts == 0 {
		c.Webhooks.MaxAttempts = def.Webhooks.MaxAttempts
	}
	if c.Webhooks.MaxRetryAge == 0 {
		c.Webhooks.MaxRetryAge = def.Webhooks.MaxRetryAge
	}
	if c.Webhooks.InitialBackoff == 0 {
		c.Webhooks.InitialBackoff = def.Webhooks.InitialBackoff
	}
	if c.Webhooks.MaxBackoff == 0 {
		c.Webhooks.MaxBackoff = def.Webhooks.MaxBackoff
	}
	if c.Webhooks.AckWait == 0 {
		c.Webhooks.AckWait = def.Webhooks.AckWait
	}
	if c.Webhooks.MaxInFlightPerSubscription == 0 {
		c.Webhooks.MaxInFlightPerSubscription = def.Webhooks.MaxInFlightPerSubscription
	}
	if c.Webhooks.MaxGlobalInFlight == 0 {
		c.Webhooks.MaxGlobalInFlight = def.Webhooks.MaxGlobalInFlight
	}
	if c.Limits.MaxSubscriptionsPerAccount == 0 {
		c.Limits.MaxSubscriptionsPerAccount = def.Limits.MaxSubscriptionsPerAccount
	}
	if c.Limits.MaxHTTPBodyBytes == 0 {
		c.Limits.MaxHTTPBodyBytes = def.Limits.MaxHTTPBodyBytes
	}
	if c.Secrets.MasterKeyFile == "" && c.Secrets.MasterKeyHex == "" {
		c.Secrets.MasterKeyFile = filepath.Join(c.DataDir, "master.key")
	}
}

func (c Config) DBPath() string {
	return filepath.Join(c.DataDir, "opendotnews.db")
}

func (c Config) Validate() error {
	switch c.Auth.Mode {
	case "local", "oauth", "disabled":
	default:
		return fmt.Errorf("invalid auth.mode %q: must be local, oauth, or disabled", c.Auth.Mode)
	}
	if c.Auth.Mode == "disabled" && !c.Auth.AllowUnsafeDisabledNonLoopback {
		if !isLoopbackListen(c.Listen) {
			return fmt.Errorf("auth.mode=disabled is only permitted on loopback listeners (got %q); set allow_unsafe_disabled_non_loopback to override", c.Listen)
		}
	}

	switch c.NATS.Mode {
	case "embedded":
		if strings.TrimSpace(c.NATS.StoreDir) == "" {
			return fmt.Errorf("nats.store_dir must be set in embedded mode")
		}
	case "external":
		if strings.TrimSpace(c.NATS.URL) == "" {
			return fmt.Errorf("nats.url must be set in external mode")
		}
	default:
		return fmt.Errorf("invalid nats.mode %q: must be embedded or external", c.NATS.Mode)
	}

	if c.Retention.MaxPayloadBytes <= 0 || c.Retention.MaxPayloadBytes > 1024*1024 {
		return fmt.Errorf("retention.max_payload_bytes must be between 1 and 1048576 (got %d)", c.Retention.MaxPayloadBytes)
	}
	if c.Retention.MaxAge <= 0 {
		return fmt.Errorf("retention.max_age must be positive")
	}
	if c.Retention.MaxStorageBytes <= 0 {
		return fmt.Errorf("retention.max_storage_bytes must be positive")
	}
	if c.Webhooks.MaxAttempts < 1 {
		return fmt.Errorf("webhooks.max_attempts must be >= 1")
	}
	if c.Webhooks.MaxInFlightPerSubscription < 1 {
		return fmt.Errorf("webhooks.max_in_flight_per_subscription must be >= 1")
	}
	if c.Webhooks.MaxGlobalInFlight < 1 {
		return fmt.Errorf("webhooks.max_global_in_flight must be >= 1")
	}
	return nil
}

func isLoopbackListen(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
