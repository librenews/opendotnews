package domain

import "errors"

var (
	ErrInvalidNamespace         = errors.New("invalid namespace")
	ErrReservedNamespace        = errors.New("namespace is reserved")
	ErrInvalidChannel           = errors.New("invalid channel")
	ErrRemoteChannelUnsupported = errors.New("remote cross-hub channels are not supported")
	ErrNamespaceTaken           = errors.New("namespace already claimed")
	ErrNamespaceNotFound        = errors.New("namespace not found")
	ErrAccountNotFound          = errors.New("account not found")
	ErrAccountDisabled          = errors.New("account is disabled")
	ErrUnauthorized             = errors.New("unauthorized")
	ErrForbidden                = errors.New("forbidden")
	ErrPayloadTooLarge          = errors.New("payload exceeds maximum size")
	ErrUnsupportedDeliveryMode  = errors.New("unsupported delivery mode")
	ErrSubscriptionNotFound     = errors.New("subscription not found")
	ErrSubscriptionConflict     = errors.New("subscription already exists with different destination")
	ErrQuotaExceeded            = errors.New("account quota exceeded")
	ErrWebhookChallengeFailed   = errors.New("webhook ownership challenge failed")
	ErrSSRFBlocked              = errors.New("webhook destination blocked by egress policy")
	ErrBrokerUnavailable        = errors.New("event broker unavailable")
	ErrInvalidCursor            = errors.New("invalid subscription start_at or cursor")
	ErrInvalidEndpoint          = errors.New("invalid webhook endpoint URL")
)
