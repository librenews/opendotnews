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

## 5. Upstream Real-Time Push (Phase 2: WebSub & rssCloud)

One shared `UpstreamPushSubscription` is maintained per canonical `Feed` (preferring WebSub when advertised, else rssCloud), managed by [Push::Reconciler](../app/services/push/reconciler.rb):

- **WebSub Subscriber ([WebSub::Subscriber](../app/services/web_sub/subscriber.rb), `/callbacks/websub/:token`):**
  - Stores `secret` and `callback_token` encrypted at rest via Active Record Encryption; looks up callbacks strictly by `callback_token_digest`.
  - Verifies intent (`subscribe` / `unsubscribe` / `denied`), enforces constant-time `X-Hub-Signature` HMAC verification, durably persists payloads in `staged_push_payloads` before returning `202 Accepted`, and ingests full RSS/Atom updates directly via `Sources::Adapters::FeedAdapter` + `Feeds::Ingest` without a follow-up HTTP fetch.
  - Malformed or non-feed payloads fail safely and fall back to a guarded `Feeds::FetchJob`.
- **rssCloud Consumer ([RssCloud::Consumer](../app/services/rss_cloud/consumer.rb), `/callbacks/rsscloud/:token`):**
  - Supports both REST (`http-post`) and XML-RPC (`pleaseNotify`) registrations with 25-hour lease / <24-hour renewal.
  - Validates challenge URLs, rejects unknown/arbitrary topic URLs and XXE payloads, and coalesces burst pings per feed into a single guarded `Feeds::FetchJob`.
- **Resilience:** Polling via `Feeds::ScheduleDueJob` remains active as a fallback if an upstream hub fails or disappears, and `Push::RenewUpstreamJob` runs every 15 minutes to renew expiring leases, retire subscriptions with zero active users, and recover any orphaned `staged_push_payloads`.

---

## 6. Markdown Publishing & Downstream Real-Time Syndication (Phases 3 & 4)

Each user owns a `Publication` bound to their `namespace`, with revisioned `Document` / `DocumentRevision` rows served under `/:namespace/*path` (with `Accept: text/markdown` vs sanitized HTML, `Vary: Accept`, distinct ETags, optional `.md` alias, and `410 Gone` soft-delete tombstones) plus generated RSS 2.0 (`/:namespace/feed.xml`) and Atom 1.0 (`/:namespace/feed.atom`).

Every public publication mutation commits a `publication.feed_changed` row to `outbox_events`, which dispatches `Publishing::FanoutFeedChangeJob` (`Events::PublicationFanout`) to active `DownstreamSubscription` rows:

- **WebSub Hub ([WebSub::Hub](../app/services/web_sub/hub.rb), `POST /websub/hub`):**
  - Resolves topics exclusively via [Publishing::HostedTopicResolver](../app/services/publishing/hosted_topic_resolver.rb) (rejects external URLs, private publications, SSRF targets, and secrets >= 200 bytes).
  - Verifies intent via `WebSub::VerifySubscriptionJob` before activation, enforces finite clamped leases, encrypts subscriber secrets at rest, and delivers full RSS/Atom XML (`WebSub::DeliverContentJob`) with `X-Hub-Signature: sha256=<hex>` and `Link` headers.
- **rssCloud Cloud Server ([RssCloud::Cloud](../app/services/rss_cloud/cloud.rb), `POST /rsscloud/pleaseNotify`, `POST /rsscloud/RPC2`, `POST /rsscloud/ping`):**
  - Verifies callback reachability & challenge before activation, enforces 25-hour finite leases, rejects XXE and non-owned topics, and delivers lightweight feed-URL pings (`RssCloud::DeliverPingJob`) in `http-post` or `xml-rpc` format.
- **Delivery Policy & Visibility:**
  - [Delivery::OutcomeHandler](../app/services/delivery/outcome_handler.rb) marks `2xx` delivered, auto-unsubscribes on `410 Gone`, suspends on SSRF or repeated permanent `4xx`, and schedules exponential retries (respecting `Retry-After`) picked up every minute by `Delivery::RetryDueJob`.
  - `Maintenance::ExpireLeasesJob` expires lapsed leases every 15 minutes; publication owners inspect subscribers and attempts at `/publishing/deliveries`.
