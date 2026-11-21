package auth

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/librenews/opendotnews/internal/config"
	"github.com/librenews/opendotnews/internal/domain"
	"github.com/librenews/opendotnews/internal/store"
)

// TokenVerifier validates a bearer credential and returns the authenticated Principal.
type TokenVerifier interface {
	Verify(ctx context.Context, rawToken string) (domain.Principal, error)
}

// HashToken returns the hex-encoded SHA-256 hash of a raw bearer token.
func HashToken(rawToken string) string {
	sum := sha256.Sum256([]byte(rawToken))
	return hex.EncodeToString(sum[:])
}

// LocalVerifier validates static config tokens, admin token, and database-persisted local tokens.
type LocalVerifier struct {
	adminToken   string
	staticTokens []config.LocalTokenConfig
	store        store.Store
}

func NewLocalVerifier(cfg config.AuthConfig, st store.Store) *LocalVerifier {
	return &LocalVerifier{
		adminToken:   cfg.AdminToken,
		staticTokens: cfg.LocalTokens,
		store:        st,
	}
}

func (v *LocalVerifier) Verify(ctx context.Context, rawToken string) (domain.Principal, error) {
	rawToken = strings.TrimSpace(rawToken)
	if rawToken == "" {
		return domain.Principal{}, domain.ErrUnauthorized
	}

	if v.adminToken != "" && subtle.ConstantTimeCompare([]byte(rawToken), []byte(v.adminToken)) == 1 {
		return domain.Principal{
			AccountID: "admin",
			Subject:   "admin",
			IsAdmin:   true,
			Scopes: map[string]bool{
				domain.ScopeEventsPublish:      true,
				domain.ScopeSubscriptionsWrite: true,
				domain.ScopeSubscriptionsRead:  true,
			},
		}, nil
	}

	for _, tok := range v.staticTokens {
		if tok.Token != "" && subtle.ConstantTimeCompare([]byte(rawToken), []byte(tok.Token)) == 1 {
			if err := v.ensureAccountActive(ctx, tok.AccountID); err != nil {
				return domain.Principal{}, err
			}
			return domain.Principal{
				AccountID: tok.AccountID,
				Subject:   tok.Subject,
				IsAdmin:   tok.IsAdmin,
				Scopes:    toScopeMap(tok.Scopes),
			}, nil
		}
	}

	if v.store != nil {
		rec, err := v.store.GetLocalTokenByHash(ctx, HashToken(rawToken))
		if err != nil {
			return domain.Principal{}, domain.ErrUnauthorized
		}
		if rec.Revoked {
			return domain.Principal{}, domain.ErrUnauthorized
		}
		if err := v.ensureAccountActive(ctx, rec.AccountID); err != nil {
			return domain.Principal{}, err
		}
		return domain.Principal{
			AccountID: rec.AccountID,
			Subject:   rec.Subject,
			IsAdmin:   rec.IsAdmin,
			Scopes:    toScopeMap(rec.Scopes),
		}, nil
	}

	return domain.Principal{}, domain.ErrUnauthorized
}

func (v *LocalVerifier) ensureAccountActive(ctx context.Context, accountID string) error {
	if v.store == nil || accountID == "" {
		return nil
	}
	acc, err := v.store.GetAccount(ctx, accountID)
	if err != nil {
		return domain.ErrUnauthorized
	}
	if acc.Status != domain.AccountStatusActive {
		return domain.ErrAccountDisabled
	}
	return nil
}

// DisabledVerifier is strictly for loopback-only local development when auth.mode=disabled.
type DisabledVerifier struct {
	defaultAccountID string
}

func NewDisabledVerifier(defaultAccountID string) *DisabledVerifier {
	if defaultAccountID == "" {
		defaultAccountID = "local-dev"
	}
	return &DisabledVerifier{defaultAccountID: defaultAccountID}
}

func (v *DisabledVerifier) Verify(_ context.Context, _ string) (domain.Principal, error) {
	return domain.Principal{
		AccountID: v.defaultAccountID,
		Subject:   "local-dev",
		IsAdmin:   true,
		Scopes: map[string]bool{
			domain.ScopeEventsPublish:      true,
			domain.ScopeSubscriptionsWrite: true,
			domain.ScopeSubscriptionsRead:  true,
		},
	}, nil
}

// ExtractBearer parses an "Authorization: Bearer <token>" header value.
func ExtractBearer(header string) (string, error) {
	if header == "" {
		return "", domain.ErrUnauthorized
	}
	parts := strings.SplitN(header, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || strings.TrimSpace(parts[1]) == "" {
		return "", fmt.Errorf("%w: malformed authorization header", domain.ErrUnauthorized)
	}
	return strings.TrimSpace(parts[1]), nil
}

func toScopeMap(scopes []string) map[string]bool {
	m := make(map[string]bool, len(scopes))
	for _, s := range scopes {
		s = strings.TrimSpace(s)
		if s != "" {
			m[s] = true
		}
	}
	return m
}
