package delivery

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/librenews/opendotnews/internal/broker"
	"github.com/librenews/opendotnews/internal/config"
	"github.com/librenews/opendotnews/internal/domain"
	"github.com/librenews/opendotnews/internal/secret"
	"github.com/librenews/opendotnews/internal/store"
)

const max4xxAttempts = 3

// Manager coordinates bounded per-subscription delivery workers.
type Manager struct {
	cfg       config.WebhookConfig
	store     store.Store
	broker    broker.Broker
	protector secret.Protector
	adapter   Adapter
	logger    *slog.Logger

	globalSem chan struct{}

	mu      sync.Mutex
	workers map[string]context.CancelFunc
	wg      sync.WaitGroup
	stopped bool
}

func NewManager(
	cfg config.WebhookConfig,
	st store.Store,
	br broker.Broker,
	prot secret.Protector,
	adapter Adapter,
	logger *slog.Logger,
) *Manager {
	if logger == nil {
		logger = slog.Default()
	}
	globalCap := cfg.MaxGlobalInFlight
	if globalCap < 1 {
		globalCap = 64
	}
	return &Manager{
		cfg:       cfg,
		store:     st,
		broker:    br,
		protector: prot,
		adapter:   adapter,
		logger:    logger,
		globalSem: make(chan struct{}, globalCap),
		workers:   make(map[string]context.CancelFunc),
	}
}

// StartSubscription starts (or restarts) a delivery worker for an active subscription.
func (m *Manager) StartSubscription(sub domain.Subscription) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.stopped {
		return
	}
	if cancel, exists := m.workers[sub.ID]; exists {
		cancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.workers[sub.ID] = cancel
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		defer func() {
			m.mu.Lock()
			// Only remove our own entry if not replaced.
			delete(m.workers, sub.ID)
			m.mu.Unlock()
		}()
		m.runWorker(ctx, sub)
	}()
}

// StopSubscription cancels a subscription's delivery worker if running.
func (m *Manager) StopSubscription(subscriptionID string) {
	m.mu.Lock()
	cancel, ok := m.workers[subscriptionID]
	if ok {
		delete(m.workers, subscriptionID)
	}
	m.mu.Unlock()
	if ok {
		cancel()
	}
}

// Shutdown cancels all workers and waits up to ctx deadline for in-flight callbacks to drain.
func (m *Manager) Shutdown(ctx context.Context) error {
	m.mu.Lock()
	m.stopped = true
	for id, cancel := range m.workers {
		cancel()
		delete(m.workers, id)
	}
	m.mu.Unlock()

	done := make(chan struct{})
	go func() {
		m.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (m *Manager) runWorker(ctx context.Context, sub domain.Subscription) {
	signingSecret, err := m.protector.Decrypt(sub.EncryptedSecret)
	if err != nil {
		m.logger.Error("failed to decrypt subscription signing secret",
			"subscription_id", sub.ID,
			"error", err,
		)
		_ = m.store.UpdateSubscriptionStatus(context.Background(), sub.ID, domain.SubscriptionStatusUnhealthy, "signing secret unavailable")
		return
	}

	perSubCap := m.cfg.MaxInFlightPerSubscription
	if perSubCap < 1 {
		perSubCap = 1
	}
	subSem := make(chan struct{}, perSubCap)

	// Track the oldest unacked sequence and the highest stream sequence at which this
	// consumer was verified caught up, so we detect retention eviction whether messages
	// expired during retry or while queued behind a slow/offline receiver.
	var (
		stateMu          sync.Mutex
		pendingFailedSeq uint64
		pendingFailedID  string
		caughtUpSeq      uint64 = sub.LastDeliveredSeq
		hasBaseline      bool
		lastGapReported  uint64
		inFlightCount    int
		inFlightWG       sync.WaitGroup
	)

	if sub.LastDeliveredSeq > 0 {
		hasBaseline = true
	} else if stInfo, err := m.broker.StreamInfo(ctx); err == nil {
		if sub.StartAt == "earliest_available" {
			caughtUpSeq = 0
		} else {
			caughtUpSeq = stInfo.LastSeq
		}
		hasBaseline = true
	}

	// Check for retention gap upon worker startup/resumption if the subscription previously
	// delivered events or paused with pending backlog.
	m.checkStartupGap(ctx, sub, &lastGapReported)

	fetchWait := 350 * time.Millisecond

	for {
		if ctx.Err() != nil {
			inFlightWG.Wait()
			return
		}

		// Periodically check if any pending/unfetched message was evicted by stream retention.
		if stInfo, sErr := m.broker.StreamInfo(ctx); sErr == nil {
			stateMu.Lock()
			if pendingFailedSeq > 0 && stInfo.FirstSeq > pendingFailedSeq && stInfo.FirstSeq > lastGapReported {
				m.recordRetentionGap(sub.ID, pendingFailedID, pendingFailedSeq, stInfo.FirstSeq)
				pendingFailedSeq = 0
				pendingFailedID = ""
				lastGapReported = stInfo.FirstSeq
				if stInfo.FirstSeq > caughtUpSeq {
					caughtUpSeq = stInfo.FirstSeq - 1
				}
			} else if hasBaseline && stInfo.FirstSeq > caughtUpSeq+1 && stInfo.FirstSeq > lastGapReported {
				m.recordRetentionGap(sub.ID, "", caughtUpSeq+1, stInfo.FirstSeq)
				lastGapReported = stInfo.FirstSeq
				caughtUpSeq = stInfo.FirstSeq - 1
			}
			stateMu.Unlock()
		}

		msgs, err := m.broker.Fetch(ctx, sub.DurableConsumer, perSubCap, fetchWait)
		if err != nil {
			if ctx.Err() != nil {
				inFlightWG.Wait()
				return
			}
			select {
			case <-ctx.Done():
				inFlightWG.Wait()
				return
			case <-time.After(300 * time.Millisecond):
			}
			continue
		}

		if len(msgs) == 0 {
			// When idle with nothing in flight and no failed message pending, advance caughtUpSeq
			// to stream.LastSeq so normal aging of unrelated channels never triggers false gaps.
			stateMu.Lock()
			idle := inFlightCount == 0 && pendingFailedSeq == 0
			stateMu.Unlock()
			if idle {
				if stInfo, sErr := m.broker.StreamInfo(ctx); sErr == nil {
					stateMu.Lock()
					hasBaseline = true
					if stInfo.LastSeq > caughtUpSeq {
						caughtUpSeq = stInfo.LastSeq
					}
					stateMu.Unlock()
				}
			}
			continue
		}

		for _, msg := range msgs {
			// Acquire per-subscription and global concurrency slots.
			select {
			case subSem <- struct{}{}:
			case <-ctx.Done():
				inFlightWG.Wait()
				return
			}
			select {
			case m.globalSem <- struct{}{}:
			case <-ctx.Done():
				<-subSem
				inFlightWG.Wait()
				return
			}

			stateMu.Lock()
			inFlightCount++
			stateMu.Unlock()

			inFlightWG.Add(1)
			go func(bm broker.Message) {
				defer inFlightWG.Done()
				defer func() {
					stateMu.Lock()
					inFlightCount--
					stateMu.Unlock()
					<-m.globalSem
					<-subSem
				}()

				ev := bm.Event()
				seq := bm.StreamSeq()
				attempt := int(bm.NumDelivered())

				// Detect if earlier queued or failed events were evicted before advancing to seq.
				stateMu.Lock()
				checkSeq := uint64(0)
				checkID := ""
				if pendingFailedSeq > 0 && seq > pendingFailedSeq {
					checkSeq = pendingFailedSeq
					checkID = pendingFailedID
					pendingFailedSeq = 0
					pendingFailedID = ""
				} else if hasBaseline && seq > caughtUpSeq+1 {
					checkSeq = caughtUpSeq + 1
				}
				alreadyReported := lastGapReported
				stateMu.Unlock()

				if checkSeq > 0 {
					if stInfo, sErr := m.broker.StreamInfo(ctx); sErr == nil && stInfo.FirstSeq > checkSeq && stInfo.FirstSeq > alreadyReported {
						m.recordRetentionGap(sub.ID, checkID, checkSeq, stInfo.FirstSeq)
						stateMu.Lock()
						if stInfo.FirstSeq > lastGapReported {
							lastGapReported = stInfo.FirstSeq
						}
						stateMu.Unlock()
					}
				}

				start := time.Now()
				// Use a bounded delivery context independent of the fetch-loop cancellation
				// so graceful shutdown drains in-flight callbacks cleanly instead of aborting mid-POST.
				deliverTimeout := m.cfg.Timeout
				if deliverTimeout <= 0 {
					deliverTimeout = 10 * time.Second
				}
				deliverCtx, deliverCancel := context.WithTimeout(context.Background(), deliverTimeout)
				res := m.adapter.Deliver(deliverCtx, sub, signingSecret, ev)
				deliverCancel()
				elapsed := time.Since(start)

				switch res.Outcome {
				case OutcomeSuccess:
					ackCtx, ackCancel := context.WithTimeout(context.Background(), 3*time.Second)
					ackErr := bm.Ack(ackCtx)
					ackCancel()
					if ackErr != nil {
						m.logger.Warn("failed to ack broker message after webhook 2xx",
							"subscription_id", sub.ID,
							"event_id", ev.EventID,
							"error", ackErr,
						)
						return
					}
					stateMu.Lock()
					if pendingFailedSeq == seq {
						pendingFailedSeq = 0
						pendingFailedID = ""
					}
					if seq > caughtUpSeq {
						caughtUpSeq = seq
					}
					stateMu.Unlock()

					_ = m.store.UpdateSubscriptionProgress(context.Background(), sub.ID, seq, time.Now().UTC())
					m.logger.Info("delivered webhook event",
						"subscription_id", sub.ID,
						"event_id", ev.EventID,
						"http_status", res.HTTPStatus,
						"attempt", attempt,
						"latency_ms", elapsed.Milliseconds(),
					)

				case OutcomeSSRFBlocked:
					_ = bm.NakWithDelay(ctx, 0)
					m.failAndPauseSubscription(sub.ID, ev.EventID, res.Category, res.HTTPStatus, res.Err.Error(), attempt)
					m.StopSubscription(sub.ID)

				case OutcomePermanent4xx:
					max4 := minInt(max4xxAttempts, m.cfg.MaxAttempts)
					if attempt >= max4 {
						_ = bm.NakWithDelay(ctx, 0)
						m.failAndPauseSubscription(sub.ID, ev.EventID, domain.FailureCategoryHTTP4xx, res.HTTPStatus, res.Err.Error(), attempt)
						m.StopSubscription(sub.ID)
						return
					}
					delay := ComputeBackoff(attempt, m.cfg.InitialBackoff, m.cfg.MaxBackoff, 0)
					_ = bm.NakWithDelay(ctx, delay)
					m.logger.Warn("webhook 4xx error; bounded retry scheduled",
						"subscription_id", sub.ID,
						"event_id", ev.EventID,
						"http_status", res.HTTPStatus,
						"attempt", attempt,
						"retry_in", delay.String(),
					)

				case OutcomeRetryable:
					stateMu.Lock()
					if pendingFailedSeq == 0 || seq < pendingFailedSeq {
						pendingFailedSeq = seq
						pendingFailedID = ev.EventID
					}
					stateMu.Unlock()

					ageExceeded := m.cfg.MaxRetryAge > 0 && time.Since(ev.PublishedAt) > m.cfg.MaxRetryAge
					if attempt >= m.cfg.MaxAttempts || ageExceeded {
						_ = bm.NakWithDelay(ctx, 0)
						msg := fmt.Sprintf("exhausted retries (%d attempts): %v", attempt, res.Err)
						m.failAndPauseSubscription(sub.ID, ev.EventID, domain.FailureCategoryRetryExhausted, res.HTTPStatus, msg, attempt)
						m.StopSubscription(sub.ID)
						return
					}

					delay := ComputeBackoff(attempt, m.cfg.InitialBackoff, m.cfg.MaxBackoff, res.RetryAfter)
					_ = bm.NakWithDelay(ctx, delay)
					m.logger.Warn("webhook delivery failed; retry scheduled",
						"subscription_id", sub.ID,
						"event_id", ev.EventID,
						"category", res.Category,
						"http_status", res.HTTPStatus,
						"attempt", attempt,
						"retry_in", delay.String(),
						"latency_ms", elapsed.Milliseconds(),
					)
				}
			}(msg)
		}
	}
}

func (m *Manager) checkStartupGap(ctx context.Context, sub domain.Subscription, lastGapReported *uint64) {
	stInfo, err := m.broker.StreamInfo(ctx)
	if err != nil || stInfo.FirstSeq <= 1 {
		return
	}
	cInfo, err := m.broker.ConsumerInfo(ctx, sub.DurableConsumer)
	if err != nil {
		return
	}
	// If the consumer had previously acknowledged up to floor > 0 (or subscription had LastDeliveredSeq > 0)
	// and stream FirstSeq moved strictly past it while consumer ack floor fell behind, expose a gap diagnostic.
	floor := cInfo.AckFloorStream
	if floor == 0 {
		floor = sub.LastDeliveredSeq
	}
	if floor > 0 && stInfo.FirstSeq > floor+1 && (cInfo.DeliveredStream < stInfo.FirstSeq || sub.LastError != "") {
		m.recordRetentionGap(sub.ID, "", floor, stInfo.FirstSeq)
		*lastGapReported = stInfo.FirstSeq
	}
}

func (m *Manager) recordRetentionGap(subscriptionID, eventID string, expectedSeq, streamFirstSeq uint64) {
	msg := fmt.Sprintf("events expired by stream retention before delivery (expected_seq=%d, stream_first_seq=%d)", expectedSeq, streamFirstSeq)
	_ = m.store.RecordDeliveryFailure(context.Background(), domain.DeliveryFailure{
		SubscriptionID:  subscriptionID,
		EventID:         eventID,
		FailureCategory: domain.FailureCategoryRetentionGap,
		ErrorMessage:    msg,
	})
	m.logger.Warn("retention gap detected for subscription",
		"subscription_id", subscriptionID,
		"event_id", eventID,
		"expected_seq", expectedSeq,
		"stream_first_seq", streamFirstSeq,
	)
}

func (m *Manager) failAndPauseSubscription(subscriptionID, eventID string, cat domain.FailureCategory, httpStatus int, errMsg string, attempts int) {
	bg := context.Background()
	_ = m.store.RecordDeliveryFailure(bg, domain.DeliveryFailure{
		SubscriptionID:  subscriptionID,
		EventID:         eventID,
		FailureCategory: cat,
		HTTPStatus:      httpStatus,
		ErrorMessage:    errMsg,
		Attempts:        attempts,
	})
	_ = m.store.UpdateSubscriptionStatus(bg, subscriptionID, domain.SubscriptionStatusUnhealthy, errMsg)
	m.logger.Error("subscription marked unhealthy and paused",
		"subscription_id", subscriptionID,
		"event_id", eventID,
		"category", cat,
		"http_status", httpStatus,
		"attempts", attempts,
		"error", errMsg,
	)
}

// ComputeBackoff computes exponential backoff with +/-25% jitter, respecting bounded Retry-After.
func ComputeBackoff(attempt int, initial, maxBackoff, retryAfter time.Duration) time.Duration {
	if initial <= 0 {
		initial = time.Second
	}
	if maxBackoff <= 0 {
		maxBackoff = 5 * time.Minute
	}
	if attempt < 1 {
		attempt = 1
	}

	delay := initial
	for i := 1; i < attempt; i++ {
		if delay >= maxBackoff/2 {
			delay = maxBackoff
			break
		}
		delay *= 2
	}
	if delay > maxBackoff {
		delay = maxBackoff
	}

	// Apply +/-25% jitter so failing endpoints do not synchronize retries.
	jitterFactor := 0.75 + rand.Float64()*0.5
	delay = time.Duration(float64(delay) * jitterFactor)
	if delay > maxBackoff {
		delay = maxBackoff
	}

	if retryAfter > delay {
		if retryAfter > maxBackoff {
			return maxBackoff
		}
		return retryAfter
	}
	return delay
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
