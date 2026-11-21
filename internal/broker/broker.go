package broker

import (
	"context"
	"time"

	"github.com/librenews/opendotnews/internal/domain"
)

// PublishMessage contains the opaque event bytes and transport metadata to persist.
type PublishMessage struct {
	Subject        string
	EventID        string
	Channel        string
	PublishedAt    time.Time
	ContentType    string
	Payload        []byte
	IdempotencyKey string
}

// PublishAck confirms durable broker persistence.
type PublishAck struct {
	StreamSeq uint64
	Duplicate bool
}

// ConsumerSpec defines a durable filtered consumer for one subscription.
type ConsumerSpec struct {
	DurableName   string
	FilterSubject string
	StartPolicy   domain.StartPolicy
	AckWait       time.Duration
	MaxDeliver    int
}

// ConsumerState summarizes a durable consumer's current JetStream state.
type ConsumerState struct {
	DurableName     string
	NumPending      uint64
	NumAckPending   int
	DeliveredStream uint64
	AckFloorStream  uint64
}

// StreamState summarizes the shared event stream's retention bounds.
type StreamState struct {
	Name      string
	Messages  uint64
	Bytes     uint64
	FirstSeq  uint64
	LastSeq   uint64
	FirstTime time.Time
	LastTime  time.Time
}

// Message is a single event fetched from a durable consumer awaiting explicit ack/nak.
type Message interface {
	Event() domain.Event
	NumDelivered() uint64
	StreamSeq() uint64
	ConsumerSeq() uint64
	Ack(ctx context.Context) error
	NakWithDelay(ctx context.Context, delay time.Duration) error
	Term(ctx context.Context) error
}

// Broker abstracts the durable pub/sub backend (NATS JetStream in v0.1).
type Broker interface {
	Publish(ctx context.Context, msg PublishMessage) (PublishAck, error)
	EnsureConsumer(ctx context.Context, spec ConsumerSpec) error
	DeleteConsumer(ctx context.Context, durableName string) error
	Fetch(ctx context.Context, durableName string, batch int, maxWait time.Duration) ([]Message, error)
	ConsumerInfo(ctx context.Context, durableName string) (ConsumerState, error)
	StreamInfo(ctx context.Context) (StreamState, error)
	Ping(ctx context.Context) error
	Close() error
}
