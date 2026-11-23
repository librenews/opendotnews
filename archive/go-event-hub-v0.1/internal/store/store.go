package store

import (
	"context"
	"time"

	"github.com/librenews/opendotnews/internal/domain"
)

// LocalTokenRecord represents a persisted local API token (stored as a SHA-256 hash).
type LocalTokenRecord struct {
	ID        string
	AccountID string
	Subject   string
	TokenHash string
	Scopes    []string
	IsAdmin   bool
	Revoked   bool
	CreatedAt time.Time
}

// Store defines the metadata persistence boundary (SQLite in v0.1, swappable for Postgres later).
type Store interface {
	Close() error
	Ping(ctx context.Context) error

	// Accounts
	CreateAccount(ctx context.Context, acc domain.Account) error
	GetAccount(ctx context.Context, id string) (domain.Account, error)
	ListAccounts(ctx context.Context) ([]domain.Account, error)
	UpdateAccountStatus(ctx context.Context, id string, status domain.AccountStatus) error

	// Local tokens
	CreateLocalToken(ctx context.Context, tok LocalTokenRecord) error
	GetLocalTokenByHash(ctx context.Context, tokenHash string) (LocalTokenRecord, error)
	RevokeAccountTokens(ctx context.Context, accountID string) error

	// Namespaces
	ClaimNamespace(ctx context.Context, ns domain.Namespace) error
	GetNamespaceByName(ctx context.Context, canonicalName string) (domain.Namespace, error)
	ListNamespaces(ctx context.Context) ([]domain.Namespace, error)

	// Channels
	GetOrCreateChannel(ctx context.Context, ch domain.Channel) (domain.Channel, error)
	GetChannelByCanonical(ctx context.Context, namespaceID, canonicalPath string) (domain.Channel, error)
	ListChannels(ctx context.Context) ([]domain.Channel, error)

	// Subscriptions
	CreateSubscription(ctx context.Context, sub domain.Subscription) error
	GetSubscription(ctx context.Context, id string) (domain.Subscription, error)
	FindActiveSubscription(ctx context.Context, accountID, channelID string) (domain.Subscription, error)
	CountActiveSubscriptionsByAccount(ctx context.Context, accountID string) (int, error)
	ListSubscriptions(ctx context.Context, statuses ...domain.SubscriptionStatus) ([]domain.Subscription, error)
	ListSubscriptionsByAccount(ctx context.Context, accountID string) ([]domain.Subscription, error)
	UpdateSubscriptionStatus(ctx context.Context, id string, status domain.SubscriptionStatus, lastErr string) error
	UpdateSubscriptionProgress(ctx context.Context, id string, lastSeq uint64, successAt time.Time) error
	UpdateSubscriptionSigningKey(ctx context.Context, id, keyID, encryptedSecret string) error

	// Delivery diagnostics
	RecordDeliveryFailure(ctx context.Context, f domain.DeliveryFailure) error
	ListDeliveryFailures(ctx context.Context, subscriptionID string, limit int) ([]domain.DeliveryFailure, error)
}
