# Open.News — Shared Content Architecture

Open.News is a single-monolith Rails 8 application backed by **PostgreSQL 17** and **Sidekiq + Redis**, designed around a **shared content core with strict per-user authorization and private state**.

---

## 1. Core Data Model Separation

```text
Shared Content Layer (stored & fetched once globally)
  feeds (canonical_url, source_type, source_metadata, push discovery, fetch diagnostics)
   ├── feed_aliases (redirect / discovery / input URLs -> feed_id)
   └── feed_items (unique [feed_id, external_id], generated tsvector FTS, metadata)
        └── feed_item_revisions (append-only snapshots on meaningful content_hash changes)

Per-User Layer (private by default, strictly scoped by user_id)
  user_feed_subscriptions (active follow relationship, optional folder)
  user_items              (LAZILY created on read / save / archive — never eagerly on ingest)
  user_inbox_events       (monotonic bigint cursor stream for disconnected AI agents)
  opml_imports            (bounded per-user import status & error summary)

Durable Internal Processing
  outbox_events           (committed atomically with content mutations; FOR UPDATE SKIP LOCKED)
  idempotency_keys        (mutation deduplication)
  audit_logs              (redacted actor/scope/resource audit trail)
```

### Key Invariants

1. **Shared upstream ingestion:** A canonical `Feed` is stored and fetched once regardless of how many users subscribe to it.
2. **Lazy `UserItem` rows:** Incoming feed items never eagerly create `UserItem` rows for every subscriber. A `UserItem` is inserted only when a user explicitly marks an item read, saved, or archived via [UserItems::UpdateState](../app/services/user_items/update_state.rb). Queries filter unread/saved/archived state using `LEFT OUTER JOIN user_items ON ... AND user_items.user_id = ?`.
3. **Private search & reading:** Full-text search (`feed_items.search_vector` via PostgreSQL `websearch_to_tsquery` + GIN index) always restricts results to `UserFeedSubscription.active.where(user_id:)`. User reading/saving activity is private to the owner.

---

## 2. Extensible Ingestion Pipeline & Source Adapter Contract

Every ingestion path separates five responsibilities:

```text
Fetch (adapter) -> Parse & Normalize (adapter) -> Persist + Outbox (Feeds::Ingest) -> Dispatch (OutboxDispatch) -> Fanout (InboxFanout)
```

### Source Adapter Contract

All source adapters inherit from [Sources::Adapters::Base](../app/services/sources/adapters/base.rb) and register with [Sources::Registry](../app/services/sources/registry.rb) by `source_type`:

- **`fetch(source)`** returns a [Sources::FetchResult](../app/services/sources/fetch_result.rb) carrying `:status` (`:ok`, `:not_modified`, `:error`), normalized items (`Sources::NormalizedItem`), source attributes/metadata, HTTP status, duration, and diagnostics.
- **`parse_payload(raw_body, headers:, base_url:)`** parses an already-delivered payload (used identically by polling today and WebSub fat-push ingestion in Phase 2).

The built-in [Sources::Adapters::FeedAdapter](../app/services/sources/adapters/feed_adapter.rb) wraps `Security::SafeHttpFetch`, `Feeds::Parse` (strict Nokogiri, XXE/DTD disabled), and `Feeds::Normalize` (Loofah XSS sanitization + deterministic ID priority). Future `"web"` or `"browser"` adapters plug into `Sources::Registry` without modifying `FeedItem`, `Feeds::Ingest`, `OutboxEvent`, `UserItem`, or `Search::Items`.

---

## 3. Idempotency, Revision Awareness & Concurrency

- **Stable item identity:** `atom:id` / `rss:guid` → normalized canonical `external_url` → `fallback:<sha256>`. If a source later supplies a real GUID for an item previously ingested under `fallback:*` with the same `[feed_id, external_url]`, `Feeds::Ingest` promotes the existing row instead of duplicating it.
- **Revision tracking:** `FeedItem` maintains `first_seen_at`, `published_at` (preserved across revisions), `source_updated_at`, `last_seen_at`, `updated_at`, `content_hash`, and `current_revision_number`. Meaningful `content_hash` changes append a `FeedItemRevision` and emit `feed_item.updated`; unchanged re-ingests only bump `last_seen_at`.
- **Concurrency safety:** [Feeds::Ingest](../app/services/feeds/ingest.rb) acquires a PostgreSQL transaction-scoped advisory lock (`pg_try_advisory_xact_lock`) per feed and wraps writes in savepoint-guarded `RecordNotUnique` handling. Polling, webhook push, and Sidekiq retries all converge on the exact same `FeedItem`, `OutboxEvent`, and `UserInboxEvent` rows (`insert_all(..., unique_by:)`).

---

## 4. Operational Visibility & Phase 2 Readiness

Each `Feed` records operational diagnostics needed to debug polling, WebSub, and rssCloud:

- `last_fetched_at`, `last_successful_fetch_at` (preserved across transient failures), `last_changed_at`, `next_fetch_at`
- `last_http_status`, `last_fetch_duration_ms`, `fetch_failure_count`, `last_error_at`, `last_error`
- `last_ingestion_method` (`poll`, `discover`, future `websub` / `rsscloud`)
- `discovered_websub_hub`, `discovered_websub_topic`, `discovered_rsscloud_endpoint`, `discovered_rsscloud_protocol`
- `last_diagnostics` JSONB snapshot (item counts, redirect count, response bytes, protocol advertisement flags)

Authorized subscribers and admins can inspect per-feed diagnostics at `GET /feeds/:id` and via MCP `list_subscriptions` / `subscribe_feed`.
