package domain

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	ScopeEventsPublish      = "events:publish"
	ScopeSubscriptionsWrite = "subscriptions:write"
	ScopeSubscriptionsRead  = "subscriptions:read"
)

type AccountStatus string

const (
	AccountStatusActive   AccountStatus = "active"
	AccountStatusDisabled AccountStatus = "disabled"
)

type Account struct {
	ID              string
	ExternalSubject string
	Status          AccountStatus
	CreatedAt       time.Time
}

type Namespace struct {
	ID            string
	AccountID     string
	CanonicalName string
	CreatedAt     time.Time
}

type Channel struct {
	ID            string
	NamespaceID   string
	CanonicalPath string
	CanonicalName string
	NATSSubject   string
	CreatedAt     time.Time
}

type DeliveryMode string

const (
	DeliveryModeWebhook DeliveryMode = "webhook"
	DeliveryModeStream  DeliveryMode = "stream"
	DeliveryModeMCP     DeliveryMode = "mcp"
)

type SubscriptionStatus string

const (
	SubscriptionStatusProvisioning SubscriptionStatus = "provisioning"
	SubscriptionStatusActive       SubscriptionStatus = "active"
	SubscriptionStatusPaused       SubscriptionStatus = "paused"
	SubscriptionStatusUnhealthy    SubscriptionStatus = "unhealthy"
	SubscriptionStatusDeleting     SubscriptionStatus = "deleting"
	SubscriptionStatusDeleted      SubscriptionStatus = "deleted"
)

type StartPolicy struct {
	Mode      string // "new", "earliest_available", "seq"
	StartSeq  uint64
}

func ParseStartAt(raw string) (StartPolicy, error) {
	if raw == "" || raw == "new" {
		return StartPolicy{Mode: "new"}, nil
	}
	if raw == "earliest_available" {
		return StartPolicy{Mode: "earliest_available"}, nil
	}
	if strings.HasPrefix(raw, "seq:") {
		v, err := strconv.ParseUint(strings.TrimPrefix(raw, "seq:"), 10, 64)
		if err != nil || v == 0 {
			return StartPolicy{}, fmt.Errorf("%w: invalid sequence cursor %q", ErrInvalidCursor, raw)
		}
		return StartPolicy{Mode: "seq", StartSeq: v}, nil
	}
	return StartPolicy{}, fmt.Errorf("%w: unsupported start_at %q", ErrInvalidCursor, raw)
}

func (s StartPolicy) String() string {
	if s.Mode == "seq" {
		return fmt.Sprintf("seq:%d", s.StartSeq)
	}
	if s.Mode == "" {
		return "new"
	}
	return s.Mode
}

type Subscription struct {
	ID               string
	AccountID        string
	ChannelID        string
	CanonicalChannel string
	NATSSubject      string
	DeliveryMode     DeliveryMode
	Endpoint         string
	SigningKeyID     string
	EncryptedSecret  string
	DurableConsumer  string
	StartAt          string
	Status           SubscriptionStatus
	LastDeliveredSeq uint64
	CreatedAt        time.Time
	UpdatedAt        time.Time
	LastSuccessAt    *time.Time
	LastError        string
}

type FailureCategory string

const (
	FailureCategoryHTTP4xx        FailureCategory = "http_4xx"
	FailureCategoryHTTP5xx        FailureCategory = "http_5xx"
	FailureCategoryNetworkError   FailureCategory = "network_error"
	FailureCategoryTimeout        FailureCategory = "timeout"
	FailureCategoryRetryExhausted FailureCategory = "retry_exhausted"
	FailureCategoryRetentionGap   FailureCategory = "retention_gap"
	FailureCategorySSRFBlocked    FailureCategory = "ssrf_blocked"
)

type DeliveryFailure struct {
	ID              string
	SubscriptionID  string
	EventID         string
	FailureCategory FailureCategory
	HTTPStatus      int
	ErrorMessage    string
	Attempts        int
	RecordedAt      time.Time
}

type Event struct {
	EventID     string
	Channel     string
	PublishedAt time.Time
	ContentType string
	Payload     []byte
	StreamSeq   uint64
}

type Principal struct {
	AccountID string
	Subject   string
	Scopes    map[string]bool
	IsAdmin   bool
}

func (p Principal) HasScope(scope string) bool {
	if p.IsAdmin {
		return true
	}
	return p.Scopes[scope]
}

type PublishInput struct {
	Channel        string
	Payload        []byte
	ContentType    string
	IdempotencyKey string
}

type PublishResult struct {
	EventID    string    `json:"event_id"`
	Channel    string    `json:"channel"`
	AcceptedAt time.Time `json:"accepted_at"`
	Status     string    `json:"status"`
	StreamSeq  uint64    `json:"-"`
}

type SubscribeInput struct {
	Channel      string
	DeliveryMode DeliveryMode
	Endpoint     string
	StartAt      string
	Replace      bool
}

type SubscribeResult struct {
	SubscriptionID   string             `json:"subscription_id"`
	Channel          string             `json:"channel"`
	Mode             DeliveryMode       `json:"mode"`
	Status           SubscriptionStatus `json:"status"`
	SigningKeyID     string             `json:"signing_key_id,omitempty"`
	SigningSecret    string             `json:"signing_secret,omitempty"`
	RetentionMaxAge  string             `json:"retention_max_age,omitempty"`
	Existing         bool               `json:"-"`
}

type UnsubscribeInput struct {
	SubscriptionID string
}

type UnsubscribeResult struct {
	Status string `json:"status"`
}
