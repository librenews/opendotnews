package sqlite

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"github.com/librenews/opendotnews/internal/domain"
	"github.com/librenews/opendotnews/internal/store"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// SQLiteStore implements store.Store backed by pure-Go SQLite in WAL mode.
type SQLiteStore struct {
	db *sql.DB
}

// Open initializes (or opens) a SQLite database at dbPath, enables WAL and foreign keys,
// and applies any pending embedded schema migrations.
func Open(ctx context.Context, dbPath string) (*SQLiteStore, error) {
	if dbPath != ":memory:" {
		if err := os.MkdirAll(filepath.Dir(dbPath), 0o750); err != nil {
			return nil, fmt.Errorf("create sqlite directory: %w", err)
		}
	}

	dsn := fmt.Sprintf("file:%s?_pragma=busy_timeout(5000)&_pragma=foreign_keys(ON)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)", dbPath)
	if dbPath == ":memory:" {
		dsn = "file::memory:?cache=shared&_pragma=foreign_keys(ON)"
	}

	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite %q: %w", dbPath, err)
	}
	// Single-connection pool prevents SQLITE_BUSY write contention across goroutines
	// while keeping control-plane reads/writes fast and deterministic.
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}

	s := &SQLiteStore{db: db}
	if err := s.migrate(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("migrate sqlite: %w", err)
	}
	return s, nil
}

func (s *SQLiteStore) Close() error {
	return s.db.Close()
}

func (s *SQLiteStore) Ping(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

func (s *SQLiteStore) migrate(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version INTEGER PRIMARY KEY,
			applied_at TEXT NOT NULL
		)`); err != nil {
		return err
	}

	entries, err := migrationsFS.ReadDir("migrations")
	if err != nil {
		return err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })

	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		parts := strings.SplitN(entry.Name(), "_", 2)
		ver, err := strconv.Atoi(parts[0])
		if err != nil {
			return fmt.Errorf("invalid migration filename %q: %w", entry.Name(), err)
		}

		var exists int
		err = s.db.QueryRowContext(ctx, `SELECT 1 FROM schema_migrations WHERE version = ?`, ver).Scan(&exists)
		if err == nil {
			continue
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return err
		}

		sqlBytes, err := migrationsFS.ReadFile("migrations/" + entry.Name())
		if err != nil {
			return err
		}

		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, string(sqlBytes)); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("apply migration %s: %w", entry.Name(), err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations(version, applied_at) VALUES(?, ?)`, ver, formatTime(time.Now().UTC())); err != nil {
			_ = tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

// --- Accounts ---

func (s *SQLiteStore) CreateAccount(ctx context.Context, acc domain.Account) error {
	if acc.Status == "" {
		acc.Status = domain.AccountStatusActive
	}
	if acc.CreatedAt.IsZero() {
		acc.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO accounts(id, external_subject, status, created_at) VALUES(?, ?, ?, ?)`,
		acc.ID, acc.ExternalSubject, string(acc.Status), formatTime(acc.CreatedAt),
	)
	if err != nil {
		return fmt.Errorf("create account: %w", err)
	}
	return nil
}

func (s *SQLiteStore) GetAccount(ctx context.Context, id string) (domain.Account, error) {
	var acc domain.Account
	var status, createdAt string
	err := s.db.QueryRowContext(ctx,
		`SELECT id, external_subject, status, created_at FROM accounts WHERE id = ?`, id,
	).Scan(&acc.ID, &acc.ExternalSubject, &status, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Account{}, domain.ErrAccountNotFound
	}
	if err != nil {
		return domain.Account{}, err
	}
	acc.Status = domain.AccountStatus(status)
	acc.CreatedAt = parseTime(createdAt)
	return acc, nil
}

func (s *SQLiteStore) ListAccounts(ctx context.Context) ([]domain.Account, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, external_subject, status, created_at FROM accounts ORDER BY created_at ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []domain.Account
	for rows.Next() {
		var acc domain.Account
		var status, createdAt string
		if err := rows.Scan(&acc.ID, &acc.ExternalSubject, &status, &createdAt); err != nil {
			return nil, err
		}
		acc.Status = domain.AccountStatus(status)
		acc.CreatedAt = parseTime(createdAt)
		out = append(out, acc)
	}
	return out, rows.Err()
}

func (s *SQLiteStore) UpdateAccountStatus(ctx context.Context, id string, status domain.AccountStatus) error {
	res, err := s.db.ExecContext(ctx, `UPDATE accounts SET status = ? WHERE id = ?`, string(status), id)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return domain.ErrAccountNotFound
	}
	return nil
}

// --- Local Tokens ---

func (s *SQLiteStore) CreateLocalToken(ctx context.Context, tok store.LocalTokenRecord) error {
	if tok.CreatedAt.IsZero() {
		tok.CreatedAt = time.Now().UTC()
	}
	isAdmin := 0
	if tok.IsAdmin {
		isAdmin = 1
	}
	revoked := 0
	if tok.Revoked {
		revoked = 1
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO local_tokens(id, account_id, subject, token_hash, scopes, is_admin, revoked, created_at)
		 VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
		tok.ID, tok.AccountID, tok.Subject, tok.TokenHash, strings.Join(tok.Scopes, ","), isAdmin, revoked, formatTime(tok.CreatedAt),
	)
	return err
}

func (s *SQLiteStore) GetLocalTokenByHash(ctx context.Context, tokenHash string) (store.LocalTokenRecord, error) {
	var rec store.LocalTokenRecord
	var scopesStr, createdAt string
	var isAdmin, revoked int
	err := s.db.QueryRowContext(ctx,
		`SELECT id, account_id, subject, token_hash, scopes, is_admin, revoked, created_at
		 FROM local_tokens WHERE token_hash = ?`, tokenHash,
	).Scan(&rec.ID, &rec.AccountID, &rec.Subject, &rec.TokenHash, &scopesStr, &isAdmin, &revoked, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return store.LocalTokenRecord{}, domain.ErrUnauthorized
	}
	if err != nil {
		return store.LocalTokenRecord{}, err
	}
	if scopesStr != "" {
		rec.Scopes = strings.Split(scopesStr, ",")
	}
	rec.IsAdmin = isAdmin != 0
	rec.Revoked = revoked != 0
	rec.CreatedAt = parseTime(createdAt)
	return rec, nil
}

func (s *SQLiteStore) RevokeAccountTokens(ctx context.Context, accountID string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE local_tokens SET revoked = 1 WHERE account_id = ?`, accountID)
	return err
}

// --- Namespaces ---

func (s *SQLiteStore) ClaimNamespace(ctx context.Context, ns domain.Namespace) error {
	if ns.CreatedAt.IsZero() {
		ns.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO namespaces(id, account_id, canonical_name, created_at) VALUES(?, ?, ?, ?)`,
		ns.ID, ns.AccountID, ns.CanonicalName, formatTime(ns.CreatedAt),
	)
	if err != nil {
		if isUniqueViolation(err) {
			return domain.ErrNamespaceTaken
		}
		return fmt.Errorf("claim namespace: %w", err)
	}
	return nil
}

func (s *SQLiteStore) GetNamespaceByName(ctx context.Context, canonicalName string) (domain.Namespace, error) {
	var ns domain.Namespace
	var createdAt string
	err := s.db.QueryRowContext(ctx,
		`SELECT id, account_id, canonical_name, created_at FROM namespaces WHERE canonical_name = ?`,
		canonicalName,
	).Scan(&ns.ID, &ns.AccountID, &ns.CanonicalName, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Namespace{}, domain.ErrNamespaceNotFound
	}
	if err != nil {
		return domain.Namespace{}, err
	}
	ns.CreatedAt = parseTime(createdAt)
	return ns, nil
}

func (s *SQLiteStore) ListNamespaces(ctx context.Context) ([]domain.Namespace, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, account_id, canonical_name, created_at FROM namespaces ORDER BY canonical_name ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []domain.Namespace
	for rows.Next() {
		var ns domain.Namespace
		var createdAt string
		if err := rows.Scan(&ns.ID, &ns.AccountID, &ns.CanonicalName, &createdAt); err != nil {
			return nil, err
		}
		ns.CreatedAt = parseTime(createdAt)
		out = append(out, ns)
	}
	return out, rows.Err()
}

// --- Channels ---

func (s *SQLiteStore) GetOrCreateChannel(ctx context.Context, ch domain.Channel) (domain.Channel, error) {
	if ch.CreatedAt.IsZero() {
		ch.CreatedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO channels(id, namespace_id, canonical_path, canonical_name, nats_subject, created_at)
		 VALUES(?, ?, ?, ?, ?, ?)`,
		ch.ID, ch.NamespaceID, ch.CanonicalPath, ch.CanonicalName, ch.NATSSubject, formatTime(ch.CreatedAt),
	)
	if err != nil {
		return domain.Channel{}, fmt.Errorf("insert channel: %w", err)
	}
	return s.GetChannelByCanonical(ctx, ch.NamespaceID, ch.CanonicalPath)
}

func (s *SQLiteStore) GetChannelByCanonical(ctx context.Context, namespaceID, canonicalPath string) (domain.Channel, error) {
	var ch domain.Channel
	var createdAt string
	err := s.db.QueryRowContext(ctx,
		`SELECT id, namespace_id, canonical_path, canonical_name, nats_subject, created_at
		 FROM channels WHERE namespace_id = ? AND canonical_path = ?`,
		namespaceID, canonicalPath,
	).Scan(&ch.ID, &ch.NamespaceID, &ch.CanonicalPath, &ch.CanonicalName, &ch.NATSSubject, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Channel{}, sql.ErrNoRows
	}
	if err != nil {
		return domain.Channel{}, err
	}
	ch.CreatedAt = parseTime(createdAt)
	return ch, nil
}

func (s *SQLiteStore) ListChannels(ctx context.Context) ([]domain.Channel, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, namespace_id, canonical_path, canonical_name, nats_subject, created_at
		 FROM channels ORDER BY canonical_name ASC`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []domain.Channel
	for rows.Next() {
		var ch domain.Channel
		var createdAt string
		if err := rows.Scan(&ch.ID, &ch.NamespaceID, &ch.CanonicalPath, &ch.CanonicalName, &ch.NATSSubject, &createdAt); err != nil {
			return nil, err
		}
		ch.CreatedAt = parseTime(createdAt)
		out = append(out, ch)
	}
	return out, rows.Err()
}

// --- Subscriptions ---

func (s *SQLiteStore) CreateSubscription(ctx context.Context, sub domain.Subscription) error {
	now := time.Now().UTC()
	if sub.CreatedAt.IsZero() {
		sub.CreatedAt = now
	}
	if sub.UpdatedAt.IsZero() {
		sub.UpdatedAt = now
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO subscriptions(
			id, account_id, channel_id, canonical_channel, nats_subject,
			delivery_mode, endpoint, signing_key_id, encrypted_secret,
			durable_consumer, start_at, status, last_delivered_seq,
			created_at, updated_at, last_error
		) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		sub.ID, sub.AccountID, sub.ChannelID, sub.CanonicalChannel, sub.NATSSubject,
		string(sub.DeliveryMode), sub.Endpoint, sub.SigningKeyID, sub.EncryptedSecret,
		sub.DurableConsumer, sub.StartAt, string(sub.Status), sub.LastDeliveredSeq,
		formatTime(sub.CreatedAt), formatTime(sub.UpdatedAt), sub.LastError,
	)
	if err != nil {
		return fmt.Errorf("create subscription: %w", err)
	}
	return nil
}

func (s *SQLiteStore) GetSubscription(ctx context.Context, id string) (domain.Subscription, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT id, account_id, channel_id, canonical_channel, nats_subject,
		        delivery_mode, endpoint, signing_key_id, encrypted_secret,
		        durable_consumer, start_at, status, last_delivered_seq,
		        created_at, updated_at, last_success_at, last_error
		 FROM subscriptions WHERE id = ?`, id,
	)
	sub, err := scanSubscription(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Subscription{}, domain.ErrSubscriptionNotFound
	}
	return sub, err
}

func (s *SQLiteStore) FindActiveSubscription(ctx context.Context, accountID, channelID string) (domain.Subscription, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT id, account_id, channel_id, canonical_channel, nats_subject,
		        delivery_mode, endpoint, signing_key_id, encrypted_secret,
		        durable_consumer, start_at, status, last_delivered_seq,
		        created_at, updated_at, last_success_at, last_error
		 FROM subscriptions
		 WHERE account_id = ? AND channel_id = ? AND status NOT IN ('deleting', 'deleted')
		 ORDER BY created_at DESC LIMIT 1`,
		accountID, channelID,
	)
	sub, err := scanSubscription(row)
	if errors.Is(err, sql.ErrNoRows) {
		return domain.Subscription{}, domain.ErrSubscriptionNotFound
	}
	return sub, err
}

func (s *SQLiteStore) CountActiveSubscriptionsByAccount(ctx context.Context, accountID string) (int, error) {
	var count int
	err := s.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM subscriptions WHERE account_id = ? AND status NOT IN ('deleting', 'deleted')`,
		accountID,
	).Scan(&count)
	return count, err
}

func (s *SQLiteStore) ListSubscriptions(ctx context.Context, statuses ...domain.SubscriptionStatus) ([]domain.Subscription, error) {
	query := `SELECT id, account_id, channel_id, canonical_channel, nats_subject,
		        delivery_mode, endpoint, signing_key_id, encrypted_secret,
		        durable_consumer, start_at, status, last_delivered_seq,
		        created_at, updated_at, last_success_at, last_error
		 FROM subscriptions`
	var args []any
	if len(statuses) > 0 {
		placeholders := make([]string, len(statuses))
		for i, st := range statuses {
			placeholders[i] = "?"
			args = append(args, string(st))
		}
		query += " WHERE status IN (" + strings.Join(placeholders, ",") + ")"
	}
	query += " ORDER BY created_at ASC"

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []domain.Subscription
	for rows.Next() {
		sub, err := scanSubscription(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, sub)
	}
	return out, rows.Err()
}

func (s *SQLiteStore) ListSubscriptionsByAccount(ctx context.Context, accountID string) ([]domain.Subscription, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, account_id, channel_id, canonical_channel, nats_subject,
		        delivery_mode, endpoint, signing_key_id, encrypted_secret,
		        durable_consumer, start_at, status, last_delivered_seq,
		        created_at, updated_at, last_success_at, last_error
		 FROM subscriptions WHERE account_id = ? AND status != 'deleted' ORDER BY created_at ASC`,
		accountID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []domain.Subscription
	for rows.Next() {
		sub, err := scanSubscription(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, sub)
	}
	return out, rows.Err()
}

func (s *SQLiteStore) UpdateSubscriptionStatus(ctx context.Context, id string, status domain.SubscriptionStatus, lastErr string) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE subscriptions SET status = ?, last_error = ?, updated_at = ? WHERE id = ?`,
		string(status), lastErr, formatTime(time.Now().UTC()), id,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return domain.ErrSubscriptionNotFound
	}
	return nil
}

func (s *SQLiteStore) UpdateSubscriptionProgress(ctx context.Context, id string, lastSeq uint64, successAt time.Time) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE subscriptions
		 SET last_delivered_seq = CASE WHEN ? > last_delivered_seq THEN ? ELSE last_delivered_seq END,
		     last_success_at = ?,
		     last_error = '',
		     updated_at = ?
		 WHERE id = ?`,
		lastSeq, lastSeq, formatTime(successAt.UTC()), formatTime(time.Now().UTC()), id,
	)
	return err
}

func (s *SQLiteStore) UpdateSubscriptionSigningKey(ctx context.Context, id, keyID, encryptedSecret string) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE subscriptions SET signing_key_id = ?, encrypted_secret = ?, updated_at = ? WHERE id = ?`,
		keyID, encryptedSecret, formatTime(time.Now().UTC()), id,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return domain.ErrSubscriptionNotFound
	}
	return nil
}

// --- Delivery Failures ---

func (s *SQLiteStore) RecordDeliveryFailure(ctx context.Context, f domain.DeliveryFailure) error {
	if f.ID == "" {
		f.ID = domain.NewID("fail")
	}
	if f.RecordedAt.IsZero() {
		f.RecordedAt = time.Now().UTC()
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO delivery_failures(id, subscription_id, event_id, failure_category, http_status, error_message, attempts, recorded_at)
		 VALUES(?, ?, ?, ?, ?, ?, ?, ?)`,
		f.ID, f.SubscriptionID, f.EventID, string(f.FailureCategory), f.HTTPStatus, f.ErrorMessage, f.Attempts, formatTime(f.RecordedAt),
	)
	return err
}

func (s *SQLiteStore) ListDeliveryFailures(ctx context.Context, subscriptionID string, limit int) ([]domain.DeliveryFailure, error) {
	if limit <= 0 {
		limit = 50
	}
	var rows *sql.Rows
	var err error
	if subscriptionID != "" {
		rows, err = s.db.QueryContext(ctx,
			`SELECT id, subscription_id, event_id, failure_category, http_status, error_message, attempts, recorded_at
			 FROM delivery_failures WHERE subscription_id = ? ORDER BY recorded_at DESC LIMIT ?`,
			subscriptionID, limit,
		)
	} else {
		rows, err = s.db.QueryContext(ctx,
			`SELECT id, subscription_id, event_id, failure_category, http_status, error_message, attempts, recorded_at
			 FROM delivery_failures ORDER BY recorded_at DESC LIMIT ?`,
			limit,
		)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []domain.DeliveryFailure
	for rows.Next() {
		var f domain.DeliveryFailure
		var cat, recordedAt string
		if err := rows.Scan(&f.ID, &f.SubscriptionID, &f.EventID, &cat, &f.HTTPStatus, &f.ErrorMessage, &f.Attempts, &recordedAt); err != nil {
			return nil, err
		}
		f.FailureCategory = domain.FailureCategory(cat)
		f.RecordedAt = parseTime(recordedAt)
		out = append(out, f)
	}
	return out, rows.Err()
}

type scanner interface {
	Scan(dest ...any) error
}

func scanSubscription(s scanner) (domain.Subscription, error) {
	var sub domain.Subscription
	var mode, status, createdAt, updatedAt string
	var lastSuccess sql.NullString
	err := s.Scan(
		&sub.ID, &sub.AccountID, &sub.ChannelID, &sub.CanonicalChannel, &sub.NATSSubject,
		&mode, &sub.Endpoint, &sub.SigningKeyID, &sub.EncryptedSecret,
		&sub.DurableConsumer, &sub.StartAt, &status, &sub.LastDeliveredSeq,
		&createdAt, &updatedAt, &lastSuccess, &sub.LastError,
	)
	if err != nil {
		return domain.Subscription{}, err
	}
	sub.DeliveryMode = domain.DeliveryMode(mode)
	sub.Status = domain.SubscriptionStatus(status)
	sub.CreatedAt = parseTime(createdAt)
	sub.UpdatedAt = parseTime(updatedAt)
	if lastSuccess.Valid && lastSuccess.String != "" {
		t := parseTime(lastSuccess.String)
		sub.LastSuccessAt = &t
	}
	return sub, nil
}

func formatTime(t time.Time) string {
	return t.UTC().Format(time.RFC3339Nano)
}

func parseTime(raw string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		t, _ = time.Parse(time.RFC3339, raw)
	}
	return t
}

func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "UNIQUE constraint failed") || strings.Contains(msg, "constraint failed")
}
