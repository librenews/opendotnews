package service

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync/atomic"
	"time"

	"github.com/librenews/opendotnews/internal/auth"
	"github.com/librenews/opendotnews/internal/broker"
	"github.com/librenews/opendotnews/internal/config"
	"github.com/librenews/opendotnews/internal/delivery"
	"github.com/librenews/opendotnews/internal/domain"
	"github.com/librenews/opendotnews/internal/secret"
	"github.com/librenews/opendotnews/internal/store"
)

// Service coordinates domain rules, ACLs, metadata persistence, broker state, and delivery workers.
type Service struct {
	cfg       config.Config
	store     store.Store
	broker    broker.Broker
	protector secret.Protector
	adapter   delivery.Adapter
	manager   *delivery.Manager
	logger    *slog.Logger

	draining atomic.Bool
}

func New(
	cfg config.Config,
	st store.Store,
	br broker.Broker,
	prot secret.Protector,
	adapter delivery.Adapter,
	manager *delivery.Manager,
	logger *slog.Logger,
) *Service {
	if logger == nil {
		logger = slog.Default()
	}
	return &Service{
		cfg:       cfg,
		store:     st,
		broker:    br,
		protector: prot,
		adapter:   adapter,
		manager:   manager,
		logger:    logger,
	}
}

// Start reconciles any interrupted provisioning/deletion state and starts workers for active subscriptions.
func (s *Service) Start(ctx context.Context) error {
	s.draining.Store(false)

	subs, err := s.store.ListSubscriptions(
		ctx,
		domain.SubscriptionStatusProvisioning,
		domain.SubscriptionStatusActive,
		domain.SubscriptionStatusDeleting,
	)
	if err != nil {
		return fmt.Errorf("list subscriptions for startup reconciliation: %w", err)
	}

	for _, sub := range subs {
		switch sub.Status {
		case domain.SubscriptionStatusProvisioning:
			sp, _ := domain.ParseStartAt(sub.StartAt)
			if err := s.broker.EnsureConsumer(ctx, broker.ConsumerSpec{
				DurableName:   sub.DurableConsumer,
				FilterSubject: sub.NATSSubject,
				StartPolicy:   sp,
				AckWait:       s.cfg.Webhooks.AckWait,
			}); err != nil {
				s.logger.Error("reconcile provisioning consumer failed",
					"subscription_id", sub.ID,
					"error", err,
				)
				_ = s.store.UpdateSubscriptionStatus(ctx, sub.ID, domain.SubscriptionStatusUnhealthy, err.Error())
				continue
			}
			if err := s.store.UpdateSubscriptionStatus(ctx, sub.ID, domain.SubscriptionStatusActive, ""); err != nil {
				return err
			}
			sub.Status = domain.SubscriptionStatusActive
			s.manager.StartSubscription(sub)
			s.logger.Info("reconciled interrupted subscription provisioning", "subscription_id", sub.ID)

		case domain.SubscriptionStatusDeleting:
			if err := s.broker.DeleteConsumer(ctx, sub.DurableConsumer); err != nil {
				s.logger.Warn("reconcile consumer delete failed; will remain deleting",
					"subscription_id", sub.ID,
					"error", err,
				)
				continue
			}
			_ = s.store.UpdateSubscriptionStatus(ctx, sub.ID, domain.SubscriptionStatusDeleted, "")
			s.logger.Info("reconciled interrupted subscription deletion", "subscription_id", sub.ID)

		case domain.SubscriptionStatusActive:
			sp, _ := domain.ParseStartAt(sub.StartAt)
			if err := s.broker.EnsureConsumer(ctx, broker.ConsumerSpec{
				DurableName:   sub.DurableConsumer,
				FilterSubject: sub.NATSSubject,
				StartPolicy:   sp,
				AckWait:       s.cfg.Webhooks.AckWait,
			}); err != nil {
				s.logger.Error("ensure consumer on startup failed",
					"subscription_id", sub.ID,
					"error", err,
				)
				continue
			}
			s.manager.StartSubscription(sub)
		}
	}
	return nil
}

// Shutdown stops accepting new publishes and drains active delivery workers within ctx.
func (s *Service) Shutdown(ctx context.Context) error {
	s.draining.Store(true)
	return s.manager.Shutdown(ctx)
}

// Ready verifies both metadata storage and broker availability.
func (s *Service) Ready(ctx context.Context) error {
	if err := s.store.Ping(ctx); err != nil {
		return fmt.Errorf("metadata store not ready: %w", err)
	}
	if err := s.broker.Ping(ctx); err != nil {
		return fmt.Errorf("broker not ready: %w", err)
	}
	return nil
}

// --- Core Pub/Sub Use Cases ---

func (s *Service) Publish(ctx context.Context, principal domain.Principal, in domain.PublishInput) (domain.PublishResult, error) {
	if s.draining.Load() {
		return domain.PublishResult{}, domain.ErrBrokerUnavailable
	}
	if !principal.HasScope(domain.ScopeEventsPublish) {
		return domain.PublishResult{}, fmt.Errorf("%w: missing %s scope", domain.ErrForbidden, domain.ScopeEventsPublish)
	}

	if len(in.Payload) > s.cfg.Retention.MaxPayloadBytes {
		return domain.PublishResult{}, fmt.Errorf("%w: %d > %d bytes", domain.ErrPayloadTooLarge, len(in.Payload), s.cfg.Retention.MaxPayloadBytes)
	}

	chName, err := domain.ParseChannel(in.Channel)
	if err != nil {
		return domain.PublishResult{}, err
	}

	ns, err := s.store.GetNamespaceByName(ctx, chName.Namespace)
	if err != nil {
		return domain.PublishResult{}, err
	}
	if !principal.IsAdmin && ns.AccountID != principal.AccountID {
		return domain.PublishResult{}, fmt.Errorf("%w: account does not own namespace %q", domain.ErrForbidden, chName.Namespace)
	}

	ch, err := s.ensureChannel(ctx, ns, chName)
	if err != nil {
		return domain.PublishResult{}, err
	}

	contentType := strings.TrimSpace(in.ContentType)
	if contentType == "" {
		contentType = "application/octet-stream"
	}

	now := time.Now().UTC()
	eventID := domain.NewID("evt")

	ack, err := s.broker.Publish(ctx, broker.PublishMessage{
		Subject:        ch.NATSSubject,
		EventID:        eventID,
		Channel:        ch.CanonicalName,
		PublishedAt:    now,
		ContentType:    contentType,
		Payload:        in.Payload,
		IdempotencyKey: strings.TrimSpace(in.IdempotencyKey),
	})
	if err != nil {
		s.logger.Error("publish failed",
			"account_id", principal.AccountID,
			"channel", ch.CanonicalName,
			"error", err,
		)
		return domain.PublishResult{}, err
	}

	s.logger.Info("published event",
		"event_id", eventID,
		"channel", ch.CanonicalName,
		"stream_seq", ack.StreamSeq,
		"duplicate", ack.Duplicate,
		"payload_bytes", len(in.Payload),
	)

	return domain.PublishResult{
		EventID:    eventID,
		Channel:    ch.CanonicalName,
		AcceptedAt: now,
		Status:     "stored",
		StreamSeq:  ack.StreamSeq,
	}, nil
}

func (s *Service) Subscribe(ctx context.Context, principal domain.Principal, in domain.SubscribeInput) (domain.SubscribeResult, error) {
	if !principal.HasScope(domain.ScopeSubscriptionsWrite) {
		return domain.SubscribeResult{}, fmt.Errorf("%w: missing %s scope", domain.ErrForbidden, domain.ScopeSubscriptionsWrite)
	}

	if in.DeliveryMode == "" {
		in.DeliveryMode = domain.DeliveryModeWebhook
	}
	if in.DeliveryMode != domain.DeliveryModeWebhook {
		return domain.SubscribeResult{}, fmt.Errorf("%w: delivery mode %q is not enabled on this server (use webhook)", domain.ErrUnsupportedDeliveryMode, in.DeliveryMode)
	}

	if err := s.adapter.ValidateEndpoint(in.Endpoint); err != nil {
		return domain.SubscribeResult{}, err
	}

	startPolicy, err := domain.ParseStartAt(in.StartAt)
	if err != nil {
		return domain.SubscribeResult{}, err
	}

	chName, err := domain.ParseChannel(in.Channel)
	if err != nil {
		return domain.SubscribeResult{}, err
	}

	ns, err := s.store.GetNamespaceByName(ctx, chName.Namespace)
	if err != nil {
		return domain.SubscribeResult{}, err
	}
	ch, err := s.ensureChannel(ctx, ns, chName)
	if err != nil {
		return domain.SubscribeResult{}, err
	}

	// Idempotency & conflict check on existing subscription for (account, channel).
	existing, err := s.store.FindActiveSubscription(ctx, principal.AccountID, ch.ID)
	if err == nil {
		if existing.DeliveryMode == in.DeliveryMode && existing.Endpoint == in.Endpoint {
			return domain.SubscribeResult{
				SubscriptionID:  existing.ID,
				Channel:         existing.CanonicalChannel,
				Mode:            existing.DeliveryMode,
				Status:          existing.Status,
				SigningKeyID:    existing.SigningKeyID,
				RetentionMaxAge: s.cfg.Retention.MaxAge.String(),
				Existing:        true,
			}, nil
		}
		if !in.Replace {
			return domain.SubscribeResult{}, fmt.Errorf("%w: use replace=true or unsubscribe first to change destination", domain.ErrSubscriptionConflict)
		}
		// Explicit replacement: retire the old subscription before creating the new one.
		if _, err := s.Unsubscribe(ctx, principal, domain.UnsubscribeInput{SubscriptionID: existing.ID}); err != nil {
			return domain.SubscribeResult{}, err
		}
	} else if !errors.Is(err, domain.ErrSubscriptionNotFound) {
		return domain.SubscribeResult{}, err
	}

	// Enforce per-account subscription quota.
	count, err := s.store.CountActiveSubscriptionsByAccount(ctx, principal.AccountID)
	if err != nil {
		return domain.SubscribeResult{}, err
	}
	if count >= s.cfg.Limits.MaxSubscriptionsPerAccount {
		return domain.SubscribeResult{}, fmt.Errorf("%w: maximum %d active subscriptions per account", domain.ErrQuotaExceeded, s.cfg.Limits.MaxSubscriptionsPerAccount)
	}

	// Generate per-subscription HMAC signing key and encrypt at rest.
	rawSecret, err := domain.NewHexSecret(32)
	if err != nil {
		return domain.SubscribeResult{}, err
	}
	keyID := domain.NewID("key")
	encSecret, err := s.protector.Encrypt([]byte(rawSecret))
	if err != nil {
		return domain.SubscribeResult{}, fmt.Errorf("encrypt signing secret: %w", err)
	}

	subID := domain.NewID("sub")
	durableName := "odn_" + subID

	sub := domain.Subscription{
		ID:               subID,
		AccountID:        principal.AccountID,
		ChannelID:        ch.ID,
		CanonicalChannel: ch.CanonicalName,
		NATSSubject:      ch.NATSSubject,
		DeliveryMode:     in.DeliveryMode,
		Endpoint:         in.Endpoint,
		SigningKeyID:     keyID,
		EncryptedSecret:  encSecret,
		DurableConsumer:  durableName,
		StartAt:          startPolicy.String(),
		Status:           domain.SubscriptionStatusProvisioning,
	}

	// Verify webhook ownership BEFORE activating or persisting active state.
	if err := s.adapter.VerifyEndpoint(ctx, sub, []byte(rawSecret)); err != nil {
		return domain.SubscribeResult{}, err
	}

	// Check if explicit seq cursor is already expired past stream retention floor.
	var expiredCursorMsg string
	if startPolicy.Mode == "seq" {
		if stInfo, stErr := s.broker.StreamInfo(ctx); stErr == nil && stInfo.FirstSeq > 0 && startPolicy.StartSeq < stInfo.FirstSeq {
			expiredCursorMsg = fmt.Sprintf("requested start_at seq:%d is older than stream retention floor seq:%d", startPolicy.StartSeq, stInfo.FirstSeq)
		}
	}

	// Crash-consistent provisioning: write provisioning state -> create consumer -> activate.
	if err := s.store.CreateSubscription(ctx, sub); err != nil {
		return domain.SubscribeResult{}, err
	}

	if err := s.broker.EnsureConsumer(ctx, broker.ConsumerSpec{
		DurableName:   sub.DurableConsumer,
		FilterSubject: sub.NATSSubject,
		StartPolicy:   startPolicy,
		AckWait:       s.cfg.Webhooks.AckWait,
	}); err != nil {
		_ = s.store.UpdateSubscriptionStatus(ctx, sub.ID, domain.SubscriptionStatusUnhealthy, err.Error())
		return domain.SubscribeResult{}, err
	}

	if err := s.store.UpdateSubscriptionStatus(ctx, sub.ID, domain.SubscriptionStatusActive, ""); err != nil {
		return domain.SubscribeResult{}, err
	}
	sub.Status = domain.SubscriptionStatusActive

	if expiredCursorMsg != "" {
		_ = s.store.RecordDeliveryFailure(ctx, domain.DeliveryFailure{
			SubscriptionID:  sub.ID,
			FailureCategory: domain.FailureCategoryRetentionGap,
			ErrorMessage:    expiredCursorMsg,
		})
	}

	s.manager.StartSubscription(sub)
	s.logger.Info("created subscription",
		"subscription_id", sub.ID,
		"account_id", principal.AccountID,
		"channel", ch.CanonicalName,
		"mode", sub.DeliveryMode,
	)

	return domain.SubscribeResult{
		SubscriptionID:  sub.ID,
		Channel:         sub.CanonicalChannel,
		Mode:            sub.DeliveryMode,
		Status:          sub.Status,
		SigningKeyID:    sub.SigningKeyID,
		SigningSecret:   rawSecret,
		RetentionMaxAge: s.cfg.Retention.MaxAge.String(),
	}, nil
}

func (s *Service) Unsubscribe(ctx context.Context, principal domain.Principal, in domain.UnsubscribeInput) (domain.UnsubscribeResult, error) {
	if !principal.HasScope(domain.ScopeSubscriptionsWrite) {
		return domain.UnsubscribeResult{}, fmt.Errorf("%w: missing %s scope", domain.ErrForbidden, domain.ScopeSubscriptionsWrite)
	}
	sub, err := s.store.GetSubscription(ctx, in.SubscriptionID)
	if err != nil {
		if errors.Is(err, domain.ErrSubscriptionNotFound) {
			return domain.UnsubscribeResult{Status: "unsubscribed"}, nil
		}
		return domain.UnsubscribeResult{}, err
	}
	if !principal.IsAdmin && sub.AccountID != principal.AccountID {
		return domain.UnsubscribeResult{}, fmt.Errorf("%w: subscription belongs to another account", domain.ErrForbidden)
	}
	if sub.Status == domain.SubscriptionStatusDeleted {
		return domain.UnsubscribeResult{Status: "unsubscribed"}, nil
	}

	// Crash-consistent deletion: mark deleting -> stop worker -> delete durable consumer -> mark deleted.
	if err := s.store.UpdateSubscriptionStatus(ctx, sub.ID, domain.SubscriptionStatusDeleting, ""); err != nil {
		return domain.UnsubscribeResult{}, err
	}
	s.manager.StopSubscription(sub.ID)

	if err := s.broker.DeleteConsumer(ctx, sub.DurableConsumer); err != nil {
		return domain.UnsubscribeResult{}, err
	}
	if err := s.store.UpdateSubscriptionStatus(ctx, sub.ID, domain.SubscriptionStatusDeleted, ""); err != nil {
		return domain.UnsubscribeResult{}, err
	}

	s.logger.Info("unsubscribed",
		"subscription_id", sub.ID,
		"account_id", principal.AccountID,
	)
	return domain.UnsubscribeResult{Status: "unsubscribed"}, nil
}

// RetrySubscription reactivates an unhealthy or paused subscription and restarts its delivery worker.
func (s *Service) RetrySubscription(ctx context.Context, subscriptionID string) (domain.Subscription, error) {
	sub, err := s.store.GetSubscription(ctx, subscriptionID)
	if err != nil {
		return domain.Subscription{}, err
	}
	if sub.Status == domain.SubscriptionStatusDeleted || sub.Status == domain.SubscriptionStatusDeleting {
		return domain.Subscription{}, domain.ErrSubscriptionNotFound
	}
	sp, _ := domain.ParseStartAt(sub.StartAt)
	if err := s.broker.EnsureConsumer(ctx, broker.ConsumerSpec{
		DurableName:   sub.DurableConsumer,
		FilterSubject: sub.NATSSubject,
		StartPolicy:   sp,
		AckWait:       s.cfg.Webhooks.AckWait,
	}); err != nil {
		return domain.Subscription{}, err
	}
	if err := s.store.UpdateSubscriptionStatus(ctx, sub.ID, domain.SubscriptionStatusActive, ""); err != nil {
		return domain.Subscription{}, err
	}
	sub.Status = domain.SubscriptionStatusActive
	sub.LastError = ""
	s.manager.StartSubscription(sub)
	s.logger.Info("restarted subscription delivery", "subscription_id", sub.ID)
	return sub, nil
}

// RotateSigningSecret generates a new HMAC key for a subscription and restarts its worker.
func (s *Service) RotateSigningSecret(ctx context.Context, principal domain.Principal, subscriptionID string) (string, string, error) {
	sub, err := s.store.GetSubscription(ctx, subscriptionID)
	if err != nil {
		return "", "", err
	}
	if !principal.IsAdmin && sub.AccountID != principal.AccountID {
		return "", "", domain.ErrForbidden
	}
	rawSecret, err := domain.NewHexSecret(32)
	if err != nil {
		return "", "", err
	}
	keyID := domain.NewID("key")
	encSecret, err := s.protector.Encrypt([]byte(rawSecret))
	if err != nil {
		return "", "", err
	}
	if err := s.store.UpdateSubscriptionSigningKey(ctx, sub.ID, keyID, encSecret); err != nil {
		return "", "", err
	}
	sub.SigningKeyID = keyID
	sub.EncryptedSecret = encSecret
	if sub.Status == domain.SubscriptionStatusActive {
		s.manager.StartSubscription(sub)
	}
	s.logger.Info("rotated webhook signing key", "subscription_id", sub.ID, "key_id", keyID)
	return keyID, rawSecret, nil
}

// --- Account, Namespace & Admin Operations ---

func (s *Service) CreateAccount(ctx context.Context, externalSubject string) (domain.Account, error) {
	if strings.TrimSpace(externalSubject) == "" {
		return domain.Account{}, fmt.Errorf("external subject is required")
	}
	acc := domain.Account{
		ID:              domain.NewID("acc"),
		ExternalSubject: strings.TrimSpace(externalSubject),
		Status:          domain.AccountStatusActive,
		CreatedAt:       time.Now().UTC(),
	}
	if err := s.store.CreateAccount(ctx, acc); err != nil {
		return domain.Account{}, err
	}
	s.logger.Info("created account", "account_id", acc.ID, "subject", acc.ExternalSubject)
	return acc, nil
}

func (s *Service) DisableAccount(ctx context.Context, accountID string) error {
	if err := s.store.UpdateAccountStatus(ctx, accountID, domain.AccountStatusDisabled); err != nil {
		return err
	}
	if err := s.store.RevokeAccountTokens(ctx, accountID); err != nil {
		return err
	}
	subs, err := s.store.ListSubscriptionsByAccount(ctx, accountID)
	if err != nil {
		return err
	}
	for _, sub := range subs {
		s.manager.StopSubscription(sub.ID)
		_ = s.store.UpdateSubscriptionStatus(ctx, sub.ID, domain.SubscriptionStatusPaused, "account disabled")
	}
	s.logger.Info("disabled account and paused subscriptions", "account_id", accountID)
	return nil
}

func (s *Service) CreateLocalToken(ctx context.Context, accountID string, scopes []string, isAdmin bool) (string, error) {
	acc, err := s.store.GetAccount(ctx, accountID)
	if err != nil {
		return "", err
	}
	if acc.Status != domain.AccountStatusActive {
		return "", domain.ErrAccountDisabled
	}
	if len(scopes) == 0 {
		scopes = []string{
			domain.ScopeEventsPublish,
			domain.ScopeSubscriptionsWrite,
			domain.ScopeSubscriptionsRead,
		}
	}
	raw, err := domain.NewOpaqueToken("odn")
	if err != nil {
		return "", err
	}
	rec := store.LocalTokenRecord{
		ID:        domain.NewID("tok"),
		AccountID: acc.ID,
		Subject:   acc.ExternalSubject,
		TokenHash: auth.HashToken(raw),
		Scopes:    scopes,
		IsAdmin:   isAdmin,
		CreatedAt: time.Now().UTC(),
	}
	if err := s.store.CreateLocalToken(ctx, rec); err != nil {
		return "", err
	}
	s.logger.Info("issued local token", "account_id", acc.ID, "token_id", rec.ID)
	return raw, nil
}

func (s *Service) ClaimNamespace(ctx context.Context, accountID, rawName string) (domain.Namespace, error) {
	acc, err := s.store.GetAccount(ctx, accountID)
	if err != nil {
		return domain.Namespace{}, err
	}
	if acc.Status != domain.AccountStatusActive {
		return domain.Namespace{}, domain.ErrAccountDisabled
	}
	canonical, err := domain.ValidateNamespace(rawName)
	if err != nil {
		return domain.Namespace{}, err
	}
	ns := domain.Namespace{
		ID:            domain.NewID("ns"),
		AccountID:     accountID,
		CanonicalName: canonical,
		CreatedAt:     time.Now().UTC(),
	}
	if err := s.store.ClaimNamespace(ctx, ns); err != nil {
		return domain.Namespace{}, err
	}
	s.logger.Info("claimed namespace", "namespace", canonical, "account_id", accountID)
	return ns, nil
}

func (s *Service) ListNamespaces(ctx context.Context) ([]domain.Namespace, error) {
	return s.store.ListNamespaces(ctx)
}

func (s *Service) ListChannels(ctx context.Context) ([]domain.Channel, error) {
	return s.store.ListChannels(ctx)
}

func (s *Service) ListSubscriptions(ctx context.Context) ([]domain.Subscription, error) {
	return s.store.ListSubscriptions(ctx)
}

func (s *Service) ListDeliveryFailures(ctx context.Context, subscriptionID string, limit int) ([]domain.DeliveryFailure, error) {
	return s.store.ListDeliveryFailures(ctx, subscriptionID, limit)
}

func (s *Service) StreamState(ctx context.Context) (broker.StreamState, error) {
	return s.broker.StreamInfo(ctx)
}

func (s *Service) ensureChannel(ctx context.Context, ns domain.Namespace, chName domain.ChannelName) (domain.Channel, error) {
	existing, err := s.store.GetChannelByCanonical(ctx, ns.ID, chName.Path)
	if err == nil {
		return existing, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return domain.Channel{}, err
	}
	chID := domain.NewID("ch")
	return s.store.GetOrCreateChannel(ctx, domain.Channel{
		ID:            chID,
		NamespaceID:   ns.ID,
		CanonicalPath: chName.Path,
		CanonicalName: chName.Canonical(),
		NATSSubject:   domain.NATSSubject(ns.ID, chID),
		CreatedAt:     time.Now().UTC(),
	})
}
