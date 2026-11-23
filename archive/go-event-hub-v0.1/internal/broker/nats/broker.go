package natsbroker

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"github.com/librenews/opendotnews/internal/broker"
	"github.com/librenews/opendotnews/internal/config"
	"github.com/librenews/opendotnews/internal/domain"
)

const (
	headerEventID     = "ODN-Event-Id"
	headerChannel     = "ODN-Channel"
	headerPublishedAt = "ODN-Published-At"
	headerContentType = "ODN-Content-Type"
)

// JetStreamBroker implements broker.Broker using a single shared persistent Limits stream
// capturing `ev.>` and independent durable filtered pull consumers per subscription.
type JetStreamBroker struct {
	nc         *nats.Conn
	js         jetstream.JetStream
	streamName string
	retention  config.RetentionConfig
}

// Connect connects to an embedded or external NATS server and ensures the shared JetStream stream exists.
func Connect(ctx context.Context, url string, streamName string, retention config.RetentionConfig) (*JetStreamBroker, error) {
	if streamName == "" {
		streamName = "OPENDOTNEWS_EVENTS"
	}

	nc, err := nats.Connect(
		url,
		nats.Name("opendotnews-hub"),
		nats.Timeout(5*time.Second),
		nats.MaxReconnects(-1),
		nats.ReconnectWait(500*time.Millisecond),
	)
	if err != nil {
		return nil, fmt.Errorf("%w: connect nats: %v", domain.ErrBrokerUnavailable, err)
	}

	js, err := jetstream.New(nc)
	if err != nil {
		nc.Close()
		return nil, fmt.Errorf("%w: init jetstream: %v", domain.ErrBrokerUnavailable, err)
	}

	b := &JetStreamBroker{
		nc:         nc,
		js:         js,
		streamName: streamName,
		retention:  retention,
	}

	if err := b.ensureStream(ctx); err != nil {
		nc.Close()
		return nil, err
	}
	return b, nil
}

func (b *JetStreamBroker) ensureStream(ctx context.Context) error {
	maxMsgs := b.retention.MaxMessages
	if maxMsgs == 0 {
		maxMsgs = -1
	}
	cfg := jetstream.StreamConfig{
		Name:        b.streamName,
		Description: "opendotnews durable broadcast event stream",
		Subjects:    []string{"ev.>"},
		Retention:   jetstream.LimitsPolicy,
		Storage:     jetstream.FileStorage,
		Discard:     jetstream.DiscardOld,
		MaxAge:      b.retention.MaxAge,
		MaxBytes:    b.retention.MaxStorageBytes,
		MaxMsgs:     maxMsgs,
		MaxMsgSize:  int32(b.retention.MaxPayloadBytes + 4096), // headroom for transport headers
		Duplicates:  b.retention.DuplicatesWindow,
	}

	if _, err := b.js.CreateOrUpdateStream(ctx, cfg); err != nil {
		return fmt.Errorf("%w: ensure stream %q: %v", domain.ErrBrokerUnavailable, b.streamName, err)
	}
	return nil
}

func (b *JetStreamBroker) Publish(ctx context.Context, msg broker.PublishMessage) (broker.PublishAck, error) {
	if b.nc == nil || !b.nc.IsConnected() {
		return broker.PublishAck{}, fmt.Errorf("%w: nats not connected", domain.ErrBrokerUnavailable)
	}

	nmsg := nats.NewMsg(msg.Subject)
	nmsg.Data = msg.Payload
	nmsg.Header.Set(headerEventID, msg.EventID)
	nmsg.Header.Set(headerChannel, msg.Channel)
	nmsg.Header.Set(headerPublishedAt, msg.PublishedAt.UTC().Format(time.RFC3339Nano))
	nmsg.Header.Set(headerContentType, msg.ContentType)

	var opts []jetstream.PublishOpt
	if msg.IdempotencyKey != "" {
		opts = append(opts, jetstream.WithMsgID(msg.IdempotencyKey))
	}

	ack, err := b.js.PublishMsg(ctx, nmsg, opts...)
	if err != nil {
		return broker.PublishAck{}, fmt.Errorf("%w: jetstream publish: %v", domain.ErrBrokerUnavailable, err)
	}
	return broker.PublishAck{
		StreamSeq: ack.Sequence,
		Duplicate: ack.Duplicate,
	}, nil
}

func (b *JetStreamBroker) EnsureConsumer(ctx context.Context, spec broker.ConsumerSpec) error {
	if b.nc == nil || !b.nc.IsConnected() {
		return fmt.Errorf("%w: nats not connected", domain.ErrBrokerUnavailable)
	}

	// If consumer already exists, keep it as-is so we never reset its cursor/progress.
	if _, err := b.js.Consumer(ctx, b.streamName, spec.DurableName); err == nil {
		return nil
	} else if !errors.Is(err, jetstream.ErrConsumerNotFound) {
		return fmt.Errorf("%w: lookup consumer %q: %v", domain.ErrBrokerUnavailable, spec.DurableName, err)
	}

	ackWait := spec.AckWait
	if ackWait <= 0 {
		ackWait = 30 * time.Second
	}

	cfg := jetstream.ConsumerConfig{
		Durable:       spec.DurableName,
		FilterSubject: spec.FilterSubject,
		AckPolicy:     jetstream.AckExplicitPolicy,
		AckWait:       ackWait,
		ReplayPolicy:  jetstream.ReplayInstantPolicy,
	}
	if spec.MaxDeliver > 0 {
		cfg.MaxDeliver = spec.MaxDeliver
	}

	switch spec.StartPolicy.Mode {
	case "", "new":
		cfg.DeliverPolicy = jetstream.DeliverNewPolicy
	case "earliest_available":
		cfg.DeliverPolicy = jetstream.DeliverAllPolicy
	case "seq":
		cfg.DeliverPolicy = jetstream.DeliverByStartSequencePolicy
		cfg.OptStartSeq = spec.StartPolicy.StartSeq
	default:
		return fmt.Errorf("%w: unknown start policy %q", domain.ErrInvalidCursor, spec.StartPolicy.Mode)
	}

	if _, err := b.js.CreateConsumer(ctx, b.streamName, cfg); err != nil {
		if errors.Is(err, jetstream.ErrConsumerExists) {
			return nil
		}
		return fmt.Errorf("%w: create consumer %q: %v", domain.ErrBrokerUnavailable, spec.DurableName, err)
	}
	return nil
}

func (b *JetStreamBroker) DeleteConsumer(ctx context.Context, durableName string) error {
	if b.nc == nil || !b.nc.IsConnected() {
		return fmt.Errorf("%w: nats not connected", domain.ErrBrokerUnavailable)
	}
	err := b.js.DeleteConsumer(ctx, b.streamName, durableName)
	if errors.Is(err, jetstream.ErrConsumerNotFound) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("%w: delete consumer %q: %v", domain.ErrBrokerUnavailable, durableName, err)
	}
	return nil
}

func (b *JetStreamBroker) Fetch(ctx context.Context, durableName string, batch int, maxWait time.Duration) ([]broker.Message, error) {
	if b.nc == nil || !b.nc.IsConnected() {
		return nil, fmt.Errorf("%w: nats not connected", domain.ErrBrokerUnavailable)
	}
	cons, err := b.js.Consumer(ctx, b.streamName, durableName)
	if err != nil {
		return nil, err
	}
	if batch <= 0 {
		batch = 1
	}
	if maxWait <= 0 {
		maxWait = 500 * time.Millisecond
	}

	msgs, err := cons.Fetch(batch, jetstream.FetchMaxWait(maxWait))
	if err != nil {
		return nil, err
	}

	var out []broker.Message
	for m := range msgs.Messages() {
		meta, metaErr := m.Metadata()
		if metaErr != nil {
			continue
		}
		out = append(out, &jsMessage{
			raw:  m,
			meta: meta,
		})
	}
	if err := msgs.Error(); err != nil && !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, nats.ErrTimeout) {
		return out, err
	}
	return out, nil
}

func (b *JetStreamBroker) ConsumerInfo(ctx context.Context, durableName string) (broker.ConsumerState, error) {
	cons, err := b.js.Consumer(ctx, b.streamName, durableName)
	if err != nil {
		return broker.ConsumerState{}, err
	}
	info, err := cons.Info(ctx)
	if err != nil {
		return broker.ConsumerState{}, err
	}
	return broker.ConsumerState{
		DurableName:     durableName,
		NumPending:      info.NumPending,
		NumAckPending:   info.NumAckPending,
		DeliveredStream: info.Delivered.Stream,
		AckFloorStream:  info.AckFloor.Stream,
	}, nil
}

func (b *JetStreamBroker) StreamInfo(ctx context.Context) (broker.StreamState, error) {
	st, err := b.js.Stream(ctx, b.streamName)
	if err != nil {
		return broker.StreamState{}, err
	}
	info, err := st.Info(ctx)
	if err != nil {
		return broker.StreamState{}, err
	}
	return broker.StreamState{
		Name:      info.Config.Name,
		Messages:  info.State.Msgs,
		Bytes:     info.State.Bytes,
		FirstSeq:  info.State.FirstSeq,
		LastSeq:   info.State.LastSeq,
		FirstTime: info.State.FirstTime,
		LastTime:  info.State.LastTime,
	}, nil
}

func (b *JetStreamBroker) Ping(ctx context.Context) error {
	if b.nc == nil || !b.nc.IsConnected() {
		return fmt.Errorf("%w: nats disconnected", domain.ErrBrokerUnavailable)
	}
	_, err := b.StreamInfo(ctx)
	if err != nil {
		return fmt.Errorf("%w: %v", domain.ErrBrokerUnavailable, err)
	}
	return nil
}

func (b *JetStreamBroker) Close() error {
	if b.nc != nil {
		b.nc.Close()
	}
	return nil
}

type jsMessage struct {
	raw  jetstream.Msg
	meta *jetstream.MsgMetadata
}

func (m *jsMessage) Event() domain.Event {
	hdr := m.raw.Headers()
	pubAt, err := time.Parse(time.RFC3339Nano, hdr.Get(headerPublishedAt))
	if err != nil {
		pubAt = m.meta.Timestamp.UTC()
	}
	ct := hdr.Get(headerContentType)
	if ct == "" {
		ct = "application/octet-stream"
	}
	// Copy raw payload bytes to guarantee immutability and exact byte preservation.
	payload := make([]byte, len(m.raw.Data()))
	copy(payload, m.raw.Data())
	return domain.Event{
		EventID:     hdr.Get(headerEventID),
		Channel:     hdr.Get(headerChannel),
		PublishedAt: pubAt,
		ContentType: ct,
		Payload:     payload,
		StreamSeq:   m.meta.Sequence.Stream,
	}
}

func (m *jsMessage) NumDelivered() uint64 {
	return m.meta.NumDelivered
}

func (m *jsMessage) StreamSeq() uint64 {
	return m.meta.Sequence.Stream
}

func (m *jsMessage) ConsumerSeq() uint64 {
	return m.meta.Sequence.Consumer
}

func (m *jsMessage) Ack(ctx context.Context) error {
	if ctx == nil {
		ctx = context.Background()
	}
	return m.raw.DoubleAck(ctx)
}

func (m *jsMessage) NakWithDelay(_ context.Context, delay time.Duration) error {
	if delay <= 0 {
		return m.raw.Nak()
	}
	return m.raw.NakWithDelay(delay)
}

func (m *jsMessage) Term(_ context.Context) error {
	return m.raw.Term()
}
