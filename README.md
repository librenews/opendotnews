# Open.News

**Open.News** is an open-source, self-hostable, agent-native RSS/Atom subscription, archive, search, and Markdown publishing service built as a Rails 8 monolith with PostgreSQL and Sidekiq/Redis.

## Current Status — Phases 0, 1, 1.1, 2, 3 & 4 Complete

- **Foundation (Phase 0):** Rails 8 + PostgreSQL 17 (UUID PKs, generated weighted `tsvector` GIN full-text search, monotonic bigint inbox cursors), Sidekiq + `sidekiq-cron` + Redis, `Security::SafeHttpFetch` (manual DNS resolution + CIDR blocking + `Net::HTTP#ipaddr=` pinning, bounded redirects, gzip/deflate decompression caps), transactional outbox (`FOR UPDATE SKIP LOCKED` + `after_commit` trigger + sweeper), `/health/live` & `/health/ready`.
- **Agent-Native Feed Reader & Shared Content Core (Phase 1 & 1.1):**
  - RSS 2.0 & Atom 1.0 discovery, conditional GET (`ETag` / `Last-Modified` / `304`), strict Nokogiri XML parsing (XXE/DTD disabled), Loofah HTML sanitization, extensible `Sources::Adapters::Base` contract (`Sources::Registry`), shared upstream ingestion with PostgreSQL advisory locks + savepoint-guarded idempotent upserts, revision tracking, and adaptive polling.
  - Lazy per-user reading state (`UserItem`: read/saved/archived created only on interaction) + private search/list filters (`unread_only`, `saved_only`, `exclude_archived`).
  - Durable per-user inbox (`user_inbox_events`) with monotonic cursors and `cursor_expired` resync signaling.
  - Authorized PostgreSQL full-text search (`websearch_to_tsquery`) strictly scoped to each user's active subscriptions.
  - Bounded OPML 1.0/2.0 import and OPML 2.0 export.
  - Standards-compliant OAuth 2.1 (Doorkeeper + PKCE S256 + hashed tokens + `/.well-known/oauth-protected-resource` + `/.well-known/oauth-authorization-server` + RFC 7591 Dynamic Client Registration at `/oauth/register`) and Streamable HTTP MCP at `POST /mcp`.
  - Minimal server-rendered Rails UI (signup/namespace claim, login, feed dashboard, per-feed operational diagnostics at `/feeds/:id`, documents management at `/documents`, search, OPML import/export, OAuth connection revocation).
- **Upstream Real-Time Ingestion (Phase 2):**
  - Shared per-feed **WebSub subscriber** (`/callbacks/websub/:token`) with encrypted secrets, intent verification, constant-time `X-Hub-Signature` HMAC validation, durable staging, direct fat-push ingestion, and lease renewal.
  - Shared per-feed **rssCloud consumer** (`/callbacks/rsscloud/:token`) supporting REST `http-post` and XML-RPC `pleaseNotify`, 25h lease / <24h renewal, challenge verification, and coalesced refetches.
- **Markdown Publishing & Hosted Syndication (Phase 3):**
  - Revisioned UTF-8 Markdown documents under `/:namespace/*path` (default `draft`, optimistic locking via `expected_revision`, idempotency keys, soft-delete `410 Gone` tombstones).
  - Public delivery with `Accept: text/markdown` vs safe `Commonmarker` + `Loofah` HTML (`Vary: Accept`, representation-specific `ETag`, `304 Not Modified`, read-only `?revision=N`) plus optional `.md` alias sending `Link: <canonical>; rel="canonical"`.
  - Generated **RSS 2.0** (`/:namespace/feed.xml`) and **Atom 1.0** (`/:namespace/feed.atom`) with stable GUIDs/Atom IDs advertising both WebSub (`/websub/hub`) and rssCloud (`/rsscloud/pleaseNotify`).
  - 5 MCP publishing tools (`publish_document`, `get_document`, `update_document`, `list_documents`, `delete_document`) bringing the live MCP surface to 15 tools.
- **Downstream Real-Time Syndication (Phase 4):**
  - **WebSub Hub** (`POST /websub/hub`) restricted strictly to public hosted `/:namespace/feed.xml` and `/:namespace/feed.atom` feeds, with GET challenge verification, finite clamped leases, encrypted subscriber secrets, SSRF-safe delivery, and fat-push full XML + `X-Hub-Signature: sha256=...` HMAC + `Link` headers.
  - **rssCloud Cloud Server** (`POST /rsscloud/pleaseNotify`, `POST /rsscloud/RPC2`, guarded `POST /rsscloud/ping`) supporting REST (`http-post`) and XML-RPC registrations with challenge verification, 25-hour finite leases, XXE rejection, and lightweight feed-URL ping fanout.
  - Transactional outbox fanout (`publication.feed_changed` -> `Events::PublicationFanout`), explicit `DeliveryAttempt` tracking, exponential retry backoff (`Delivery::RetryDueJob`), automatic `410 Gone` unsubscription, periodic lease expiry (`Maintenance::ExpireLeasesJob`), and an owner delivery dashboard at `/publishing/deliveries`.
  - See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full architecture overview.

*(Phase 5 will add operational quotas, operator metrics, security hardening, and final production conformance.)*

## Local Setup (macOS / Homebrew Postgres 17 + Redis + rbenv)

```bash
cp .env.example .env
bundle install
bundle exec rails db:prepare
```

Start web + Sidekiq workers in two terminals:

```bash
bundle exec rails server
bundle exec sidekiq -C config/sidekiq.yml
```

Run the Phase 1 demo script:

```bash
bundle exec rails runner db/seeds_demo.rb
```

## Running Tests

```bash
bundle exec rspec
```

## Production Deployment (Docker + Kamal 2)

Open.News ships as a standard environment-configured Docker image ([Dockerfile](Dockerfile)) with **Kamal 2** ([config/deploy.yml](config/deploy.yml)) as the reference deployment method on a single Ubuntu VPS (separate containers for Puma, Sidekiq, PostgreSQL 17, and Redis behind Kamal Proxy HTTPS). The same image deploys unmodified on Railway, Render, or Fly.io.

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for full VPS setup, Kamal 2 commands, automated off-host PostgreSQL backups ([script/backup_postgres.sh](script/backup_postgres.sh)), and restore drills ([script/restore_postgres.sh](script/restore_postgres.sh)).

## Docker Compose (Local Development)

```bash
docker compose up --build
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
