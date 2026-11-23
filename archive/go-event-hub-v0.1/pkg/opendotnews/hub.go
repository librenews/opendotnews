package opendotnews

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/librenews/opendotnews/internal/auth"
	"github.com/librenews/opendotnews/internal/broker"
	natsbroker "github.com/librenews/opendotnews/internal/broker/nats"
	"github.com/librenews/opendotnews/internal/config"
	"github.com/librenews/opendotnews/internal/delivery"
	"github.com/librenews/opendotnews/internal/domain"
	"github.com/librenews/opendotnews/internal/embeddednats"
	"github.com/librenews/opendotnews/internal/httpapi"
	"github.com/librenews/opendotnews/internal/secret"
	"github.com/librenews/opendotnews/internal/service"
	"github.com/librenews/opendotnews/internal/store"
	"github.com/librenews/opendotnews/internal/store/sqlite"
)

const Version = "0.1.0-phase-a"

// Re-exported configuration and core types for clean Go embedding.
type (
	Config           = config.Config
	AuthConfig       = config.AuthConfig
	LocalTokenConfig = config.LocalTokenConfig
	NATSConfig       = config.NATSConfig
	RetentionConfig  = config.RetentionConfig
	WebhookConfig    = config.WebhookConfig
	LimitsConfig     = config.LimitsConfig
	SecretConfig     = config.SecretConfig

	Principal         = domain.Principal
	PublishInput      = domain.PublishInput
	PublishResult     = domain.PublishResult
	SubscribeInput    = domain.SubscribeInput
	SubscribeResult   = domain.SubscribeResult
	UnsubscribeInput  = domain.UnsubscribeInput
	UnsubscribeResult = domain.UnsubscribeResult
	DeliveryMode      = domain.DeliveryMode
	Subscription      = domain.Subscription
	DeliveryFailure   = domain.DeliveryFailure
	Event             = domain.Event
	Envelope          = delivery.Envelope
	ChallengeEnvelope = delivery.ChallengeEnvelope
	ChallengeResponse = delivery.ChallengeResponse

	Store           = store.Store
	Broker          = broker.Broker
	TokenVerifier   = auth.TokenVerifier
	DeliveryAdapter = delivery.Adapter
	SecretProtector = secret.Protector
)

const (
	DeliveryModeWebhook = domain.DeliveryModeWebhook
	DeliveryModeStream  = domain.DeliveryModeStream
	DeliveryModeMCP     = domain.DeliveryModeMCP

	ScopeEventsPublish      = domain.ScopeEventsPublish
	ScopeSubscriptionsWrite = domain.ScopeSubscriptionsWrite
	ScopeSubscriptionsRead  = domain.ScopeSubscriptionsRead

	HeaderTimestamp      = delivery.HeaderTimestamp
	HeaderEventID        = delivery.HeaderEventID
	HeaderSubscriptionID = delivery.HeaderSubscriptionID
	HeaderKeyID          = delivery.HeaderKeyID
	HeaderSignature      = delivery.HeaderSignature
	HeaderEventKind      = delivery.HeaderEventKind
)

func DefaultConfig() Config                   { return config.DefaultConfig() }
func LoadConfigFile(p string) (Config, error) { return config.LoadFile(p) }

// VerifyWebhookSignature verifies an incoming opendotnews webhook HMAC-SHA256 signature.
func VerifyWebhookSignature(secretKey []byte, timestampHeader, signatureHeader string, rawBody []byte, maxSkew time.Duration) error {
	return delivery.VerifySignature(secretKey, timestampHeader, signatureHeader, rawBody, maxSkew, time.Now().UTC())
}

// DecodeEnvelopePayload extracts the exact opaque payload bytes from a webhook Envelope.
func DecodeEnvelopePayload(env Envelope) ([]byte, error) {
	return delivery.DecodeEnvelopePayload(env)
}

// Dependencies lets embedders override any pluggable subsystem (Store, Broker, Auth, Delivery, Secrets, Logger).
// Nil fields are wired automatically from Config during Start.
type Dependencies struct {
	Store           Store
	Broker          Broker
	TokenVerifier   TokenVerifier
	DeliveryAdapter DeliveryAdapter
	SecretProtector SecretProtector
	Resolver        delivery.Resolver
	Logger          *slog.Logger
	DisableHTTP     bool // When true, Start does not bind an HTTP listener (library-only mode).
}

// Hub is an isolated, embeddable opendotnews event hub instance (no global state).
type Hub struct {
	cfg  Config
	deps Dependencies

	mu           sync.Mutex
	started      bool
	embeddedNATS *embeddednats.Server
	ownedStore   bool
	ownedBroker  bool

	store     Store
	broker    Broker
	verifier  TokenVerifier
	adapter   DeliveryAdapter
	protector SecretProtector
	manager   *delivery.Manager
	svc       *service.Service
	api       *httpapi.Server
	httpSrv   *http.Server
	listener  net.Listener
	httpErrCh chan error
}

// New validates Config and constructs an unstarted Hub instance.
func New(cfg Config, deps Dependencies) (*Hub, error) {
	cfg.ApplyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if deps.Logger == nil {
		deps.Logger = slog.Default()
	}
	return &Hub{
		cfg:  cfg,
		deps: deps,
	}, nil
}

// Start initializes storage, broker (embedded or external), reconciles subscriptions,
// launches delivery workers, and optionally starts the HTTP server.
func (h *Hub) Start(ctx context.Context) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.started {
		return errors.New("hub already started")
	}

	var cleanup []func()
	rollback := func() {
		for i := len(cleanup) - 1; i >= 0; i-- {
			cleanup[i]()
		}
	}

	// 1. Metadata store
	st := h.deps.Store
	if st == nil {
		var err error
		st, err = sqlite.Open(ctx, h.cfg.DBPath())
		if err != nil {
			rollback()
			return fmt.Errorf("open metadata store: %w", err)
		}
		h.ownedStore = true
		cleanup = append(cleanup, func() { _ = st.Close() })
	}
	h.store = st

	// 2. Secret protector
	prot := h.deps.SecretProtector
	if prot == nil {
		var err error
		prot, err = secret.LoadOrCreateMasterKey(h.cfg.Secrets.MasterKeyHex, h.cfg.Secrets.MasterKeyFile)
		if err != nil {
			rollback()
			return fmt.Errorf("init secret protector: %w", err)
		}
	}
	h.protector = prot

	// 3. Broker (embedded or external NATS JetStream)
	br := h.deps.Broker
	if br == nil {
		natsURL := h.cfg.NATS.URL
		if h.cfg.NATS.Mode == "embedded" {
			ens, err := embeddednats.Start(ctx, embeddednats.Options{
				Host:     h.cfg.NATS.Host,
				Port:     h.cfg.NATS.Port,
				StoreDir: h.cfg.NATS.StoreDir,
			})
			if err != nil {
				rollback()
				return fmt.Errorf("start embedded nats: %w", err)
			}
			h.embeddedNATS = ens
			natsURL = ens.ClientURL()
			cleanup = append(cleanup, func() { ens.Shutdown() })
		}

		jsBroker, err := natsbroker.Connect(ctx, natsURL, h.cfg.NATS.StreamName, h.cfg.Retention)
		if err != nil {
			rollback()
			return fmt.Errorf("connect nats broker: %w", err)
		}
		br = jsBroker
		h.ownedBroker = true
		cleanup = append(cleanup, func() { _ = jsBroker.Close() })
	}
	h.broker = br

	// 4. Token verifier
	ver := h.deps.TokenVerifier
	if ver == nil {
		switch h.cfg.Auth.Mode {
		case "disabled":
			ver = auth.NewDisabledVerifier("local-dev")
		case "local":
			ver = auth.NewLocalVerifier(h.cfg.Auth, h.store)
		case "oauth":
			rollback()
			return errors.New("auth.mode=oauth is scheduled for Phase B; use local or disabled in Phase A")
		}
	}
	h.verifier = ver

	// 5. Delivery adapter & worker manager
	adapter := h.deps.DeliveryAdapter
	if adapter == nil {
		adapter = delivery.NewWebhookAdapter(h.cfg.Webhooks, h.deps.Resolver)
	}
	h.adapter = adapter
	h.manager = delivery.NewManager(h.cfg.Webhooks, h.store, h.broker, h.protector, h.adapter, h.deps.Logger)

	// 6. Core service + startup reconciliation
	h.svc = service.New(h.cfg, h.store, h.broker, h.protector, h.adapter, h.manager, h.deps.Logger)
	if err := h.svc.Start(ctx); err != nil {
		rollback()
		return fmt.Errorf("start service: %w", err)
	}

	// 7. HTTP API server
	h.api = httpapi.New(h.cfg, h.svc, h.verifier, h.deps.Logger)
	if !h.deps.DisableHTTP {
		ln, err := net.Listen("tcp", h.cfg.Listen)
		if err != nil {
			_ = h.svc.Shutdown(context.Background())
			rollback()
			return fmt.Errorf("listen %q: %w", h.cfg.Listen, err)
		}
		h.listener = ln
		h.httpSrv = &http.Server{
			Handler:           h.api.Handler(),
			ReadHeaderTimeout: 10 * time.Second,
			ReadTimeout:       15 * time.Second,
			WriteTimeout:      30 * time.Second,
			IdleTimeout:       60 * time.Second,
		}
		h.httpErrCh = make(chan error, 1)
		go func() {
			err := h.httpSrv.Serve(ln)
			if err != nil && !errors.Is(err, http.ErrServerClosed) {
				h.httpErrCh <- err
			}
			close(h.httpErrCh)
		}()
	}

	h.started = true
	h.deps.Logger.Info("opendotnews hub started",
		"listen", h.Addr(),
		"nats_mode", h.cfg.NATS.Mode,
		"auth_mode", h.cfg.Auth.Mode,
	)
	return nil
}

// Shutdown gracefully stops HTTP ingress, drains bounded delivery callbacks, closes the broker,
// flushes embedded NATS storage, and closes SQLite.
func (h *Hub) Shutdown(ctx context.Context) error {
	h.mu.Lock()
	if !h.started {
		h.mu.Unlock()
		return nil
	}
	h.started = false
	h.mu.Unlock()

	var errs []error
	if h.httpSrv != nil {
		if err := h.httpSrv.Shutdown(ctx); err != nil {
			errs = append(errs, fmt.Errorf("shutdown http server: %w", err))
		}
	}
	if h.svc != nil {
		if err := h.svc.Shutdown(ctx); err != nil {
			errs = append(errs, fmt.Errorf("shutdown delivery workers: %w", err))
		}
	}
	if h.ownedBroker && h.broker != nil {
		if err := h.broker.Close(); err != nil {
			errs = append(errs, fmt.Errorf("close broker: %w", err))
		}
	}
	if h.embeddedNATS != nil {
		h.embeddedNATS.Shutdown()
	}
	if h.ownedStore && h.store != nil {
		if err := h.store.Close(); err != nil {
			errs = append(errs, fmt.Errorf("close store: %w", err))
		}
	}
	return errors.Join(errs...)
}

// Addr returns the bound HTTP listener address (useful when Listen uses ":0").
func (h *Hub) Addr() string {
	if h.listener != nil {
		return h.listener.Addr().String()
	}
	return ""
}

// NATSClientURL returns the embedded NATS client URL if running in embedded mode.
func (h *Hub) NATSClientURL() string {
	if h.embeddedNATS != nil {
		return h.embeddedNATS.ClientURL()
	}
	return h.cfg.NATS.URL
}

// Handler returns the HTTP handler for embedding into an existing net/http server.
func (h *Hub) Handler() http.Handler {
	if h.api == nil {
		return nil
	}
	return h.api.Handler()
}

// Direct Go library methods delegating to the core Service (same code path as HTTP/MCP).

func (h *Hub) Publish(ctx context.Context, p Principal, in PublishInput) (PublishResult, error) {
	return h.svc.Publish(ctx, p, in)
}

func (h *Hub) Subscribe(ctx context.Context, p Principal, in SubscribeInput) (SubscribeResult, error) {
	return h.svc.Subscribe(ctx, p, in)
}

func (h *Hub) Unsubscribe(ctx context.Context, p Principal, in UnsubscribeInput) (UnsubscribeResult, error) {
	return h.svc.Unsubscribe(ctx, p, in)
}

func (h *Hub) CreateAccount(ctx context.Context, subject string) (domain.Account, error) {
	return h.svc.CreateAccount(ctx, subject)
}

func (h *Hub) DisableAccount(ctx context.Context, accountID string) error {
	return h.svc.DisableAccount(ctx, accountID)
}

func (h *Hub) CreateLocalToken(ctx context.Context, accountID string, scopes []string, isAdmin bool) (string, error) {
	return h.svc.CreateLocalToken(ctx, accountID, scopes, isAdmin)
}

func (h *Hub) ClaimNamespace(ctx context.Context, accountID, name string) (domain.Namespace, error) {
	return h.svc.ClaimNamespace(ctx, accountID, name)
}

func (h *Hub) RetrySubscription(ctx context.Context, subscriptionID string) (Subscription, error) {
	return h.svc.RetrySubscription(ctx, subscriptionID)
}

func (h *Hub) RotateSigningSecret(ctx context.Context, p Principal, subscriptionID string) (string, string, error) {
	return h.svc.RotateSigningSecret(ctx, p, subscriptionID)
}

func (h *Hub) ListSubscriptions(ctx context.Context) ([]Subscription, error) {
	return h.svc.ListSubscriptions(ctx)
}

func (h *Hub) ListDeliveryFailures(ctx context.Context, subscriptionID string, limit int) ([]DeliveryFailure, error) {
	return h.svc.ListDeliveryFailures(ctx, subscriptionID, limit)
}

func (h *Hub) StreamState(ctx context.Context) (broker.StreamState, error) {
	return h.svc.StreamState(ctx)
}
