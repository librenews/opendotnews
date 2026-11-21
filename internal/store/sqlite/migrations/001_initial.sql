CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS accounts (
    id TEXT PRIMARY KEY,
    external_subject TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS local_tokens (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    subject TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    scopes TEXT NOT NULL,
    is_admin INTEGER NOT NULL DEFAULT 0,
    revoked INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_local_tokens_account ON local_tokens(account_id);

CREATE TABLE IF NOT EXISTS namespaces (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
    canonical_name TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_namespaces_account ON namespaces(account_id);

CREATE TABLE IF NOT EXISTS channels (
    id TEXT PRIMARY KEY,
    namespace_id TEXT NOT NULL REFERENCES namespaces(id) ON DELETE RESTRICT,
    canonical_path TEXT NOT NULL,
    canonical_name TEXT NOT NULL UNIQUE,
    nats_subject TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    UNIQUE(namespace_id, canonical_path)
);

CREATE TABLE IF NOT EXISTS subscriptions (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
    channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE RESTRICT,
    canonical_channel TEXT NOT NULL,
    nats_subject TEXT NOT NULL,
    delivery_mode TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    signing_key_id TEXT NOT NULL,
    encrypted_secret TEXT NOT NULL,
    durable_consumer TEXT NOT NULL UNIQUE,
    start_at TEXT NOT NULL,
    status TEXT NOT NULL,
    last_delivered_seq INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    last_success_at TEXT,
    last_error TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_account_channel ON subscriptions(account_id, channel_id, status);
CREATE INDEX IF NOT EXISTS idx_subscriptions_status ON subscriptions(status);

CREATE TABLE IF NOT EXISTS delivery_failures (
    id TEXT PRIMARY KEY,
    subscription_id TEXT NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    event_id TEXT NOT NULL,
    failure_category TEXT NOT NULL,
    http_status INTEGER NOT NULL DEFAULT 0,
    error_message TEXT NOT NULL DEFAULT '',
    attempts INTEGER NOT NULL DEFAULT 0,
    recorded_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_delivery_failures_sub ON delivery_failures(subscription_id, recorded_at DESC);
