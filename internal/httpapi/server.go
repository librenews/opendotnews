package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/librenews/opendotnews/internal/auth"
	"github.com/librenews/opendotnews/internal/config"
	"github.com/librenews/opendotnews/internal/domain"
	"github.com/librenews/opendotnews/internal/service"
)

type Server struct {
	cfg      config.Config
	svc      *service.Service
	verifier auth.TokenVerifier
	logger   *slog.Logger
	mux      *http.ServeMux
}

func New(cfg config.Config, svc *service.Service, verifier auth.TokenVerifier, logger *slog.Logger) *Server {
	if logger == nil {
		logger = slog.Default()
	}
	s := &Server{
		cfg:      cfg,
		svc:      svc,
		verifier: verifier,
		logger:   logger,
		mux:      http.NewServeMux(),
	}
	s.registerRoutes()
	return s
}

func (s *Server) Handler() http.Handler {
	return s.withRequestLogging(s.mux)
}

func (s *Server) registerRoutes() {
	// Public health endpoints
	s.mux.HandleFunc("GET /healthz", s.handleHealthz)
	s.mux.HandleFunc("GET /readyz", s.handleReadyz)

	// Authenticated pub/sub HTTP API (Phase A baseline; Phase B MCP shares the same Service)
	s.mux.HandleFunc("POST /v1/publish", s.requireAuth(s.handlePublish))
	s.mux.HandleFunc("POST /v1/subscriptions", s.requireAuth(s.handleSubscribe))
	s.mux.HandleFunc("DELETE /v1/subscriptions/{id}", s.requireAuth(s.handleUnsubscribe))
	s.mux.HandleFunc("GET /v1/subscriptions", s.requireAuth(s.handleListMySubscriptions))

	// Administrative endpoints (admin principal required)
	s.mux.HandleFunc("POST /admin/accounts", s.requireAdmin(s.handleAdminCreateAccount))
	s.mux.HandleFunc("POST /admin/accounts/{id}/disable", s.requireAdmin(s.handleAdminDisableAccount))
	s.mux.HandleFunc("POST /admin/accounts/{id}/tokens", s.requireAdmin(s.handleAdminCreateToken))
	s.mux.HandleFunc("POST /admin/namespaces", s.requireAdmin(s.handleAdminClaimNamespace))
	s.mux.HandleFunc("GET /admin/namespaces", s.requireAdmin(s.handleAdminListNamespaces))
	s.mux.HandleFunc("GET /admin/channels", s.requireAdmin(s.handleAdminListChannels))
	s.mux.HandleFunc("GET /admin/subscriptions", s.requireAdmin(s.handleAdminListSubscriptions))
	s.mux.HandleFunc("POST /admin/subscriptions/{id}/retry", s.requireAdmin(s.handleAdminRetrySubscription))
	s.mux.HandleFunc("GET /admin/failures", s.requireAdmin(s.handleAdminListFailures))
	s.mux.HandleFunc("GET /admin/stream", s.requireAdmin(s.handleAdminStreamInfo))
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := s.svc.Ready(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "not_ready",
			"error":  err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

type publishRequest struct {
	Channel        string          `json:"channel"`
	Payload        json.RawMessage `json:"payload,omitempty"`
	PayloadBase64  string          `json:"payload_base64,omitempty"`
	ContentType    string          `json:"content_type,omitempty"`
	IdempotencyKey string          `json:"idempotency_key,omitempty"`
}

func (s *Server) handlePublish(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req publishRequest
	if err := s.decodeBody(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	var payload []byte
	contentType := req.ContentType
	switch {
	case req.PayloadBase64 != "":
		raw, err := base64.StdEncoding.DecodeString(req.PayloadBase64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid payload_base64")
			return
		}
		payload = raw
		if contentType == "" {
			contentType = "application/octet-stream"
		}
	case len(req.Payload) > 0:
		payload = []byte(req.Payload)
		if contentType == "" {
			contentType = "application/json"
		}
	default:
		payload = []byte{}
		if contentType == "" {
			contentType = "application/octet-stream"
		}
	}

	res, err := s.svc.Publish(r.Context(), principal, domain.PublishInput{
		Channel:        req.Channel,
		Payload:        payload,
		ContentType:    contentType,
		IdempotencyKey: req.IdempotencyKey,
	})
	if err != nil {
		writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, res)
}

type subscribeRequest struct {
	Channel  string `json:"channel"`
	Delivery struct {
		Mode string `json:"mode"`
		URL  string `json:"url"`
	} `json:"delivery"`
	StartAt string `json:"start_at,omitempty"`
	Replace bool   `json:"replace,omitempty"`
}

func (s *Server) handleSubscribe(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	var req subscribeRequest
	if err := s.decodeBody(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	res, err := s.svc.Subscribe(r.Context(), principal, domain.SubscribeInput{
		Channel:      req.Channel,
		DeliveryMode: domain.DeliveryMode(req.Delivery.Mode),
		Endpoint:     req.Delivery.URL,
		StartAt:      req.StartAt,
		Replace:      req.Replace,
	})
	if err != nil {
		writeDomainError(w, err)
		return
	}
	status := http.StatusCreated
	if res.Existing {
		status = http.StatusOK
	}
	writeJSON(w, status, res)
}

func (s *Server) handleUnsubscribe(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	id := r.PathValue("id")
	res, err := s.svc.Unsubscribe(r.Context(), principal, domain.UnsubscribeInput{SubscriptionID: id})
	if err != nil {
		writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) handleListMySubscriptions(w http.ResponseWriter, r *http.Request, principal domain.Principal) {
	if !principal.HasScope(domain.ScopeSubscriptionsRead) {
		writeError(w, http.StatusForbidden, "missing subscriptions:read scope")
		return
	}
	all, err := s.svc.ListSubscriptions(r.Context())
	if err != nil {
		writeDomainError(w, err)
		return
	}
	var out []subscriptionView
	for _, sub := range all {
		if principal.IsAdmin || sub.AccountID == principal.AccountID {
			out = append(out, toSubscriptionView(sub))
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"subscriptions": out})
}

// --- Admin Handlers ---

func (s *Server) handleAdminCreateAccount(w http.ResponseWriter, r *http.Request, _ domain.Principal) {
	var req struct {
		Subject string `json:"subject"`
	}
	if err := s.decodeBody(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	acc, err := s.svc.CreateAccount(r.Context(), req.Subject)
	if err != nil {
		writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, acc)
}

func (s *Server) handleAdminDisableAccount(w http.ResponseWriter, r *http.Request, _ domain.Principal) {
	if err := s.svc.DisableAccount(r.Context(), r.PathValue("id")); err != nil {
		writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "disabled"})
}

func (s *Server) handleAdminCreateToken(w http.ResponseWriter, r *http.Request, _ domain.Principal) {
	var req struct {
		Scopes  []string `json:"scopes"`
		IsAdmin bool     `json:"is_admin"`
	}
	_ = s.decodeBody(w, r, &req)
	tok, err := s.svc.CreateLocalToken(r.Context(), r.PathValue("id"), req.Scopes, req.IsAdmin)
	if err != nil {
		writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"token": tok})
}

func (s *Server) handleAdminClaimNamespace(w http.ResponseWriter, r *http.Request, _ domain.Principal) {
	var req struct {
		AccountID string `json:"account_id"`
		Name      string `json:"name"`
	}
	if err := s.decodeBody(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	ns, err := s.svc.ClaimNamespace(r.Context(), req.AccountID, req.Name)
	if err != nil {
		writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, ns)
}

func (s *Server) handleAdminListNamespaces(w http.ResponseWriter, r *http.Request, _ domain.Principal) {
	nss, err := s.svc.ListNamespaces(r.Context())
	if err != nil {
		writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"namespaces": nss})
}

func (s *Server) handleAdminListChannels(w http.ResponseWriter, r *http.Request, _ domain.Principal) {
	chs, err := s.svc.ListChannels(r.Context())
	if err != nil {
		writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"channels": chs})
}

func (s *Server) handleAdminListSubscriptions(w http.ResponseWriter, r *http.Request, _ domain.Principal) {
	subs, err := s.svc.ListSubscriptions(r.Context())
	if err != nil {
		writeDomainError(w, err)
		return
	}
	views := make([]subscriptionView, 0, len(subs))
	for _, sub := range subs {
		views = append(views, toSubscriptionView(sub))
	}
	writeJSON(w, http.StatusOK, map[string]any{"subscriptions": views})
}

func (s *Server) handleAdminRetrySubscription(w http.ResponseWriter, r *http.Request, _ domain.Principal) {
	sub, err := s.svc.RetrySubscription(r.Context(), r.PathValue("id"))
	if err != nil {
		writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toSubscriptionView(sub))
}

func (s *Server) handleAdminListFailures(w http.ResponseWriter, r *http.Request, _ domain.Principal) {
	subID := r.URL.Query().Get("subscription_id")
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	failures, err := s.svc.ListDeliveryFailures(r.Context(), subID, limit)
	if err != nil {
		writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"failures": failures})
}

func (s *Server) handleAdminStreamInfo(w http.ResponseWriter, r *http.Request, _ domain.Principal) {
	st, err := s.svc.StreamState(r.Context())
	if err != nil {
		writeDomainError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// --- Middleware & Helpers ---

type authedHandler func(http.ResponseWriter, *http.Request, domain.Principal)

func (s *Server) requireAuth(next authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var rawToken string
		if s.cfg.Auth.Mode != "disabled" {
			var err error
			rawToken, err = auth.ExtractBearer(r.Header.Get("Authorization"))
			if err != nil {
				writeError(w, http.StatusUnauthorized, "unauthorized")
				return
			}
		}
		principal, err := s.verifier.Verify(r.Context(), rawToken)
		if err != nil {
			writeDomainError(w, err)
			return
		}
		next(w, r, principal)
	}
}

func (s *Server) requireAdmin(next authedHandler) http.HandlerFunc {
	return s.requireAuth(func(w http.ResponseWriter, r *http.Request, p domain.Principal) {
		if !p.IsAdmin {
			writeError(w, http.StatusForbidden, "admin privileges required")
			return
		}
		next(w, r, p)
	})
}

func (s *Server) decodeBody(w http.ResponseWriter, r *http.Request, dst any) error {
	maxBytes := int64(s.cfg.Limits.MaxHTTPBodyBytes)
	if maxBytes <= 0 {
		maxBytes = 128 * 1024
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(dst); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	return nil
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (sr *statusRecorder) WriteHeader(code int) {
	sr.status = code
	sr.ResponseWriter.WriteHeader(code)
}

func (s *Server) withRequestLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reqID := r.Header.Get("X-Request-Id")
		if reqID == "" {
			reqID = domain.NewID("req")
		}
		w.Header().Set("X-Request-Id", reqID)
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		start := time.Now()
		next.ServeHTTP(rec, r)
		s.logger.Info("http request",
			"request_id", reqID,
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"latency_ms", time.Since(start).Milliseconds(),
		)
	})
}

// subscriptionView deliberately omits EncryptedSecret so secrets are never leaked by API responses.
type subscriptionView struct {
	ID               string                    `json:"id"`
	AccountID        string                    `json:"account_id"`
	Channel          string                    `json:"channel"`
	DeliveryMode     domain.DeliveryMode       `json:"delivery_mode"`
	Endpoint         string                    `json:"endpoint"`
	SigningKeyID     string                    `json:"signing_key_id"`
	Status           domain.SubscriptionStatus `json:"status"`
	LastDeliveredSeq uint64                    `json:"last_delivered_seq"`
	CreatedAt        time.Time                 `json:"created_at"`
	UpdatedAt        time.Time                 `json:"updated_at"`
	LastSuccessAt    *time.Time                `json:"last_success_at,omitempty"`
	LastError        string                    `json:"last_error,omitempty"`
}

func toSubscriptionView(sub domain.Subscription) subscriptionView {
	return subscriptionView{
		ID:               sub.ID,
		AccountID:        sub.AccountID,
		Channel:          sub.CanonicalChannel,
		DeliveryMode:     sub.DeliveryMode,
		Endpoint:         sub.Endpoint,
		SigningKeyID:     sub.SigningKeyID,
		Status:           sub.Status,
		LastDeliveredSeq: sub.LastDeliveredSeq,
		CreatedAt:        sub.CreatedAt,
		UpdatedAt:        sub.UpdatedAt,
		LastSuccessAt:    sub.LastSuccessAt,
		LastError:        sub.LastError,
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func writeDomainError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrUnauthorized):
		writeError(w, http.StatusUnauthorized, err.Error())
	case errors.Is(err, domain.ErrForbidden), errors.Is(err, domain.ErrAccountDisabled):
		writeError(w, http.StatusForbidden, err.Error())
	case errors.Is(err, domain.ErrNamespaceNotFound), errors.Is(err, domain.ErrSubscriptionNotFound), errors.Is(err, domain.ErrAccountNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, domain.ErrNamespaceTaken), errors.Is(err, domain.ErrSubscriptionConflict):
		writeError(w, http.StatusConflict, err.Error())
	case errors.Is(err, domain.ErrPayloadTooLarge):
		writeError(w, http.StatusRequestEntityTooLarge, err.Error())
	case errors.Is(err, domain.ErrQuotaExceeded):
		writeError(w, http.StatusTooManyRequests, err.Error())
	case errors.Is(err, domain.ErrBrokerUnavailable):
		writeError(w, http.StatusServiceUnavailable, err.Error())
	case errors.Is(err, domain.ErrInvalidNamespace),
		errors.Is(err, domain.ErrReservedNamespace),
		errors.Is(err, domain.ErrInvalidChannel),
		errors.Is(err, domain.ErrRemoteChannelUnsupported),
		errors.Is(err, domain.ErrUnsupportedDeliveryMode),
		errors.Is(err, domain.ErrInvalidCursor),
		errors.Is(err, domain.ErrInvalidEndpoint),
		errors.Is(err, domain.ErrSSRFBlocked),
		errors.Is(err, domain.ErrWebhookChallengeFailed):
		writeError(w, http.StatusBadRequest, err.Error())
	default:
		writeError(w, http.StatusInternalServerError, "internal server error")
	}
}
