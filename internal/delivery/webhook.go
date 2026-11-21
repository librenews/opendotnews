package delivery

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/librenews/opendotnews/internal/config"
	"github.com/librenews/opendotnews/internal/domain"
)

type Outcome int

const (
	OutcomeSuccess Outcome = iota
	OutcomeRetryable
	OutcomePermanent4xx
	OutcomeSSRFBlocked
)

type DeliveryResult struct {
	Outcome    Outcome
	HTTPStatus int
	RetryAfter time.Duration
	Category   domain.FailureCategory
	Err        error
}

// Adapter delivers events and verifies endpoint ownership for a delivery mode.
type Adapter interface {
	ValidateEndpoint(rawURL string) error
	VerifyEndpoint(ctx context.Context, sub domain.Subscription, signingSecret []byte) error
	Deliver(ctx context.Context, sub domain.Subscription, signingSecret []byte, event domain.Event) DeliveryResult
}

// WebhookAdapter delivers events via authenticated HTTPS POST with HMAC-SHA256 signatures
// and connect-time SSRF protection.
type WebhookAdapter struct {
	cfg    config.WebhookConfig
	client *http.Client
	nowFn  func() time.Time
}

func NewWebhookAdapter(cfg config.WebhookConfig, resolver Resolver) *WebhookAdapter {
	return &WebhookAdapter{
		cfg:    cfg,
		client: NewSafeHTTPClient(cfg.Timeout, cfg.AllowPrivateDestinations, resolver),
		nowFn:  func() time.Time { return time.Now().UTC() },
	}
}

func (w *WebhookAdapter) ValidateEndpoint(rawURL string) error {
	_, err := ValidateEndpointURL(rawURL, w.cfg.AllowInsecureHTTP)
	return err
}

func (w *WebhookAdapter) VerifyEndpoint(ctx context.Context, sub domain.Subscription, signingSecret []byte) error {
	if err := w.ValidateEndpoint(sub.Endpoint); err != nil {
		return err
	}
	if w.cfg.SkipChallengeVerification {
		return nil
	}

	nonce, err := domain.NewHexSecret(16)
	if err != nil {
		return err
	}
	body, err := json.Marshal(ChallengeEnvelope{
		EnvelopeVersion: EnvelopeVersion,
		Type:            "webhook.challenge",
		SubscriptionID:  sub.ID,
		Channel:         sub.CanonicalChannel,
		Challenge:       nonce,
	})
	if err != nil {
		return err
	}

	ts := w.nowFn().Unix()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, sub.Endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("%w: build challenge request: %v", domain.ErrWebhookChallengeFailed, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "opendotnews/0.1")
	req.Header.Set(HeaderEventKind, EventKindChallenge)
	req.Header.Set(HeaderTimestamp, strconv.FormatInt(ts, 10))
	req.Header.Set(HeaderSubscriptionID, sub.ID)
	req.Header.Set(HeaderKeyID, sub.SigningKeyID)
	req.Header.Set(HeaderSignature, Sign(signingSecret, ts, body))

	resp, err := w.client.Do(req)
	if err != nil {
		if errors.Is(err, domain.ErrSSRFBlocked) {
			return err
		}
		return fmt.Errorf("%w: %v", domain.ErrWebhookChallengeFailed, err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("%w: receiver returned HTTP %d", domain.ErrWebhookChallengeFailed, resp.StatusCode)
	}

	var chResp ChallengeResponse
	if err := json.Unmarshal(respBody, &chResp); err != nil || chResp.Challenge != nonce {
		return fmt.Errorf("%w: receiver did not echo challenge token", domain.ErrWebhookChallengeFailed)
	}
	return nil
}

func (w *WebhookAdapter) Deliver(ctx context.Context, sub domain.Subscription, signingSecret []byte, event domain.Event) DeliveryResult {
	if err := w.ValidateEndpoint(sub.Endpoint); err != nil {
		return DeliveryResult{
			Outcome:  OutcomePermanent4xx,
			Category: domain.FailureCategoryHTTP4xx,
			Err:      err,
		}
	}

	body, err := MarshalEventEnvelope(event)
	if err != nil {
		return DeliveryResult{
			Outcome:  OutcomePermanent4xx,
			Category: domain.FailureCategoryHTTP4xx,
			Err:      fmt.Errorf("marshal envelope: %w", err),
		}
	}

	ts := w.nowFn().Unix()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, sub.Endpoint, bytes.NewReader(body))
	if err != nil {
		return DeliveryResult{
			Outcome:  OutcomePermanent4xx,
			Category: domain.FailureCategoryHTTP4xx,
			Err:      fmt.Errorf("build request: %w", err),
		}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "opendotnews/0.1")
	req.Header.Set(HeaderEventKind, EventKindEvent)
	req.Header.Set(HeaderTimestamp, strconv.FormatInt(ts, 10))
	req.Header.Set(HeaderEventID, event.EventID)
	req.Header.Set(HeaderSubscriptionID, sub.ID)
	req.Header.Set(HeaderKeyID, sub.SigningKeyID)
	req.Header.Set(HeaderSignature, Sign(signingSecret, ts, body))

	resp, err := w.client.Do(req)
	if err != nil {
		if errors.Is(err, domain.ErrSSRFBlocked) {
			return DeliveryResult{
				Outcome:  OutcomeSSRFBlocked,
				Category: domain.FailureCategorySSRFBlocked,
				Err:      err,
			}
		}
		cat := domain.FailureCategoryNetworkError
		if errors.Is(err, context.DeadlineExceeded) || isTimeoutErr(err) {
			cat = domain.FailureCategoryTimeout
		}
		return DeliveryResult{
			Outcome:  OutcomeRetryable,
			Category: cat,
			Err:      err,
		}
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))

	code := resp.StatusCode
	if code >= 200 && code < 300 {
		return DeliveryResult{
			Outcome:    OutcomeSuccess,
			HTTPStatus: code,
		}
	}

	// Redirects are disallowed by default; treat 3xx as a non-retryable configuration/policy error.
	if code >= 300 && code < 400 {
		return DeliveryResult{
			Outcome:    OutcomePermanent4xx,
			HTTPStatus: code,
			Category:   domain.FailureCategoryHTTP4xx,
			Err:        fmt.Errorf("webhook redirects are disallowed (HTTP %d)", code),
		}
	}

	if code == http.StatusRequestTimeout || code == http.StatusTooManyRequests || code >= 500 {
		cat := domain.FailureCategoryHTTP5xx
		if code == http.StatusRequestTimeout {
			cat = domain.FailureCategoryTimeout
		}
		return DeliveryResult{
			Outcome:    OutcomeRetryable,
			HTTPStatus: code,
			RetryAfter: parseRetryAfter(resp.Header.Get("Retry-After"), w.nowFn(), w.cfg.MaxBackoff),
			Category:   cat,
			Err:        fmt.Errorf("webhook returned HTTP %d", code),
		}
	}

	// 401/403 and other persistent 4xx errors.
	return DeliveryResult{
		Outcome:    OutcomePermanent4xx,
		HTTPStatus: code,
		Category:   domain.FailureCategoryHTTP4xx,
		Err:        fmt.Errorf("webhook rejected request with HTTP %d", code),
	}
}

func parseRetryAfter(hdr string, now time.Time, maxBackoff time.Duration) time.Duration {
	hdr = strings.TrimSpace(hdr)
	if hdr == "" {
		return 0
	}
	if secs, err := strconv.Atoi(hdr); err == nil && secs > 0 {
		d := time.Duration(secs) * time.Second
		if maxBackoff > 0 && d > maxBackoff {
			return maxBackoff
		}
		return d
	}
	if t, err := http.ParseTime(hdr); err == nil {
		d := t.Sub(now)
		if d <= 0 {
			return 0
		}
		if maxBackoff > 0 && d > maxBackoff {
			return maxBackoff
		}
		return d
	}
	return 0
}

func isTimeoutErr(err error) bool {
	type timeout interface{ Timeout() bool }
	var te timeout
	return errors.As(err, &te) && te.Timeout()
}
