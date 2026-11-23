# Open.News

**Open.News** is an open-source, self-hostable, agent-native RSS/Atom subscription, archive, search, and Markdown publishing service built as a Rails 8 monolith with PostgreSQL and Sidekiq/Redis.

## Current Status — Phase 0 + Phase 1 + Phase 1.1 Complete

- **Foundation (Phase 0):** Rails 8 + PostgreSQL 17 (UUID PKs, generated weighted `tsvector` GIN full-text search, monotonic bigint inbox cursors), Sidekiq + `sidekiq-cron` + Redis, `Security::SafeHttpFetch` (manual DNS resolution + CIDR blocking + `Net::HTTP#ipaddr=` pinning, bounded redirects, gzip/deflate decompression caps), transactional outbox (`FOR UPDATE SKIP LOCKED` + `after_commit` trigger + sweeper), `/health/live` & `/health/ready`.
- **Agent-Native Feed Reader & Shared Content Core (Phase 1 & 1.1):**
  - RSS 2.0 & Atom 1.0 discovery, conditional GET (`ETag` / `Last-Modified` / `304`), strict Nokogiri XML parsing (XXE/DTD disabled), Loofah HTML sanitization, extensible `Sources::Adapters::Base` contract (`Sources::Registry`), shared upstream ingestion with PostgreSQL advisory locks + savepoint-guarded idempotent upserts, revision tracking, and adaptive polling.
  - Lazy per-user reading state (`UserItem`: read/saved/archived created only on interaction) + private search/list filters (`unread_only`, `saved_only`, `exclude_archived`).
  - Durable per-user inbox (`user_inbox_events`) with monotonic cursors and `cursor_expired` resync signaling.
  - Authorized PostgreSQL full-text search (`websearch_to_tsquery`) strictly scoped to each user's active subscriptions.
  - Bounded OPML 1.0/2.0 import and OPML 2.0 export.
  - Standards-compliant OAuth 2.1 (Doorkeeper + PKCE S256 + hashed tokens + `/.well-known/oauth-protected-resource` + `/.well-known/oauth-authorization-server` + RFC 7591 Dynamic Client Registration at `/oauth/register`) and Streamable HTTP MCP at `POST /mcp` (`subscribe_feed`, `unsubscribe_feed`, `list_subscriptions`, `list_feed_items`, `get_feed_item`, `search_items`, `get_updates`, `import_opml`, `get_opml_import_status`, `export_opml`).
  - Minimal server-rendered Rails UI (signup/namespace claim, login, feed dashboard, per-feed operational diagnostics at `/feeds/:id`, search, OPML import/export, OAuth connection revocation).
  - See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the shared content model and adapter contract.

*(Phases 2–5 will add upstream WebSub/rssCloud ingestion, hosted Markdown publishing + RSS/Atom generation, downstream WebSub hub & rssCloud cloud server, and production hardening.)*

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
