# Open.News — Implementation Specification

**Version:** 1.0 (greenfield rewrite)  
**Date:** November 23, 2026  
**Status:** Build specification for coding agent  
**Target:** Open-source, self-hostable Rails monolith; hosted service at `open.news`  
**Primary audience:** Coding agent implementing the application from a fresh Rails repository

---

## 0. Executive decision and instructions to the coding agent

Build **Open.News**, an **agent-native RSS/Atom subscription, archive, search, and Markdown publishing service**, with bidirectional **rssCloud** and **WebSub** interoperability. Users connect personal AI agents (including Dots and other MCP clients) via OAuth and use them to subscribe, read, search, import/export OPML, publish Markdown documents, and receive durable updates.

**Replace**, rather than extend, the previous Go + NATS JetStream + SQLite generic agent event hub. The prior implementation solved a different problem. **Do not migrate** general-purpose event channels, direct messages, agent coordination features, arbitrary payload schemas, or embedded broker APIs into the new application.

**Use:** Rails 8, PostgreSQL, Sidekiq + Redis, server-rendered Rails administration, HTTPS, and a remote MCP server using the current supported HTTP transport. Do not introduce NATS, Kafka, graph databases, embeddings, vector databases, or microservices to the initial build.

**Critical design principles:**

1. **Useful before network effects:** anyone can subscribe to ordinary RSS/Atom feeds and search their accumulated items without anyone publishing through Open.News.
2. **Open on both sides:** the system reads existing feeds and publishes ordinary RSS 2.0/Atom plus Markdown over HTTPS. Other feed readers must work without MCP.
3. **Full-duplex syndication:** Open.News is an rssCloud client **and** cloud server; a WebSub subscriber **and** hub/publisher.
4. **Content is canonical:** one authoritative source of truth per fetched item or hosted document; transport and notifications are projections of that content.
5. **Shared upstream ingestion:** fetch/subscribe once per canonical external feed, regardless of how many users follow it. Access, unread state, and inbox cursors remain user-specific.
6. **Durable events, not a broker:** changes create transactional outbox records, which workers fan out idempotently. Assume at-least-once processing.
7. **Intelligence belongs to agents:** no built-in LLM summaries, recommendations, autonomous agents, or embeddings in version 1.
8. **Self-hostable, not embeddable:** document straightforward single-instance deployment. The application need not be a library or miniature infrastructure daemon.
9. **Protocol correctness over cosmetic completeness:** implement verification, lease renewal, HMAC, retries, and security boundaries instead of merely exposing similarly named routes.
10. **Start small, but keep extension seams:** separate feed ingestion, publishing, protocol adapters, MCP, and delivery inside one Rails monolith.

### Definition of success

A user connects Open.News to their AI agent, imports an OPML file, subscribes to additional RSS/Atom feeds, receives and searches updates through MCP, asks the agent to publish a Markdown document at a stable public HTTPS URL, and other readers can subscribe to the resulting feed using regular RSS, rssCloud, or WebSub. All of this continues to function after process restarts and temporary remote outages.

---

## 1. Scope

### 1.1 In scope (complete product target)

- Account creation/login, OAuth for remote MCP clients, namespace selection, account settings.
- External RSS 2.0 and Atom ingestion; feed autodiscovery from site URLs; one shared upstream fetch per source.
- Scheduled polling, HTTP conditional GET, deduplication, item archiving and PostgreSQL full-text search.
- Per-user subscriptions, read/bookmark optional later, durable inbox and cursor-based incremental retrieval.
- OPML import/export with per-user ownership and safe, bounded processing.
- rssCloud **consumer** (discover a cloud, register/renew, accept ping, refresh feed).
- WebSub **subscriber** (hub discovery, challenge confirmation, lease renewal, signed distribution, push ingestion).
- Hosted Markdown documents with stable paths, draft/public visibility, revision history, ETag/Last-Modified, optional simple HTML rendering.
- Generated RSS 2.0 and Atom feeds for hosted publications; stable GUIDs; update semantics; advertised real-time endpoints.
- rssCloud **cloud server** (registrations, callback verification, expirations, ping, lightweight fanout).
- WebSub **hub** (subscription verification, leases, signed fat push, delivery retries) for hosted publications.
- OAuth-protected remote MCP tools for feed reading and publishing.
- Minimal Rails web dashboard for login, subscriptions, documents, and operational troubleshooting.
- Observability, rate limits, security protections, tests, and deploy documentation.

### 1.2 Explicitly out of scope

- Generic agent-to-agent messaging, arbitrary event channel names, DMs, social graphs, follows between identities, ActivityPub/ATProto federation.
- Paid subscriptions, payment processing, team/organization accounts, arbitrary user-provided HTML/CSS/JS hosting, dynamic web applications, arbitrary file hosting.
- Custom domains in v1 (design a clear seam for later).
- AI-generated summaries, semantic/vector search, article extraction of arbitrary linked pages, web crawling beyond feed discovery.
- Syndicating *the full body of copyrighted third-party articles* as Open.News-hosted public content.
- Public general-purpose third-party hub hosting. Our outbound hub/cloud initially serves only publications hosted by Open.News; supporting independently hosted publisher topics is deferred.
- Search index infrastructure outside PostgreSQL, real-time UI updates, native mobile apps.

### 1.3 Terminology

- **Feed:** external or hosted RSS/Atom source, identified by a canonical feed URL.
- **Feed item:** a normalized immutable-origin item with versioned updates; an item may be revised by its publisher.
- **Subscription:** a user's follow relationship to a feed; not to be confused with upstream WebSub/rssCloud registrations or downstream protocol subscribers.
- **Document:** user-owned hosted Markdown resource at a stable public URL.
- **Publication:** user namespace/collection of hosted documents with generated syndication feed(s).
- **Inbox event:** durable user-visible change (new/updated feed item, relevant document update) with a monotonic cursor.
- **Upstream subscription:** Open.News's subscription to an external WebSub hub or rssCloud cloud.
- **Downstream subscription:** a third-party reader's subscription to our hosted WebSub hub or rssCloud cloud.
- **Outbox event:** a database record of something committed locally that requires asynchronous processing.

---

## 2. User journeys and acceptance scenarios

### J1. Connect a personal agent

1. User signs up, chooses unique namespace `matt` (reserved names rejected).
2. Agent connects to `https://open.news/mcp` through the platform's supported OAuth flow.
3. OAuth consent authorizes only requested scopes.
4. Agent calls `list_subscriptions`; response is empty and correctly attributed to that user.
5. User can revoke the connection and all subsequent token use fails.

### J2. Subscribe and read

1. Agent calls `subscribe_feed({url: "https://publisher.example/blog"})`.
2. Service discovers the RSS/Atom feed if URL is a webpage, canonicalizes it, returns canonical feed identity, and queues ingestion.
3. It polls the feed, archives items, discovers push metadata, and registers upstream if possible.
4. Agent calls `list_feed_items` and `search_items`, receiving title, date, author, feed, permalink, summary/content when available, plus stable item IDs.
5. A second user subscribes to the same feed; no second upstream fetch/registration is created.

### J3. Import/export OPML

1. User uploads or supplies an OPML XML document; it is parsed with bounded size and XML entity expansion disabled.
2. Each valid outline feed URL is queued; duplicates are skipped; individual errors are reported.
3. Export returns standard OPML with the user's feed URLs and hierarchical grouping if groups are retained.
4. Exporting then importing into a clean account preserves subscribed feed URLs.

### J4. External push update

1. External feed advertises WebSub and/or rssCloud; Open.News subscribes and maintains renewal.
2. On a valid WebSub delivery, normalize directly from signed pushed bytes without requiring another fetch when the payload is a usable full feed; if it is a supported delta, process safely, otherwise schedule refetch.
3. On an rssCloud ping, enqueue a guarded refetch; don't treat a ping as unverified article content.
4. New/changed items enter shared archive and create per-user durable inbox events.
5. Polling remains a fallback for push failures or unavailable protocols.

### J5. Agent publishes Markdown

1. `publish_document({path: "notes/hello", markdown: "# Hello", title: "Hello", visibility: "public"})` creates document under authenticated namespace.
2. The public URL `https://open.news/matt/notes/hello` is stable.
3. `Accept: text/markdown` returns canonical Markdown, and ordinary browser request returns securely rendered HTML. `Vary: Accept` is sent; response validators work for each representation.
4. The publication's `feed.xml` and `feed.atom` expose the document as a stable item with a stable GUID/Atom ID.
5. Updating it increments revision and notifies downstream subscribers; deleting it produces a tombstone internally, returns 404/410 by policy, and never allows another user to take over the old identity.

### J6. Third-party subscription to our feed

1. A conventional rssCloud client reads `<cloud>` metadata, registers and verifies its callback, and receives a lightweight ping when hosted feed changes.
2. A conventional WebSub client discovers hub/topic, completes challenge verification, and receives a signed feed payload when it asked for a secret.
3. Both protocols are triggered from the same committed publication event, without creating duplicate user inbox items.

---

## 3. Architecture

```text
External RSS/Atom/HTML sites
       |        |         |
     polling  rssCloud   WebSub
       |        |         |
       +--------+---------+
                |
      Fetch / discover / parse
                |
        Feed normalization
                |
      PostgreSQL (feeds, items)
                |
      Transactional event outbox
                |
         Sidekiq workers
          /            \
   User inboxes     Publication fanout
        |           /             \
    MCP reader  rssCloud cloud   WebSub hub
        ^           ^             ^
        |           |             |
     OAuth       third-party feed readers
        |
      Agents --- MCP publish --> Markdown documents
                                    |
                              RSS + Atom + HTTPS
```

### 3.1 Deployment units

- **Rails web:** Puma serving UI, MCP, OAuth, public documents, feeds, and inbound push callbacks.
- **Sidekiq worker:** queue processes for ingest, discovery, renewal, fanout, retries, inbox materialization, retention.
- **Sidekiq scheduler:** use a supported recurring-job mechanism (or separate cron process) for periodic scheduling; avoid application-server timers.
- **PostgreSQL:** authoritative content, metadata, inbox state, revisions, outbox, delivery attempts.
- **Redis:** Sidekiq queues only; Redis is not authoritative storage for documents/events.
- **Nginx or equivalent:** TLS termination, request-size limits, routing, static assets.

### 3.2 Key service boundaries

Use PORO service objects or namespace modules, without separate deployments:

```text
Feeds::Discover
Feeds::Fetch
Feeds::Parse
Feeds::Normalize
Feeds::Ingest
Feeds::Schedule
Search::Items
Opml::Import
Opml::Export
Publishing::CreateOrRevise
Publishing::Render
Publishing::Syndicate
RssCloud::Consumer
RssCloud::Cloud
WebSub::Subscriber
WebSub::Hub
Events::OutboxDispatch
Events::InboxFanout
Mcp::Tools::*
Security::SafeHttpFetch
```

Jobs are thin wrappers and must delegate to services that can be exercised synchronously in tests.

---

## 4. Data model (PostgreSQL)

Use UUID primary keys for public-facing entities where convenient, plus a **monotonic bigint** for event stream cursors. Use database uniqueness constraints, foreign keys, and `NOT NULL` for critical columns. Suggested tables:

### Identity

**users:** `id`, `email` (unique case-insensitive), `password_digest` or chosen authentication fields, `namespace` (unique case-insensitive), `created_at`, `updated_at`, `disabled_at`.

**oauth_clients / oauth_grants / oauth_tokens:** per selected standards-compliant OAuth implementation. Store client metadata and opaque/revocable grants, hashed tokens if supported; never store bearer tokens in plaintext logs.

**publications:** `id`, `user_id`, `slug`, `title`, `description`, `visibility` (default public), timestamps. In v1 one default publication per user, with room for multiple later. Unique `[user_id, slug]`.

### Reader

**feeds:** `id`, `canonical_url` (unique), `site_url`, `title`, `description`, `format` (`rss`, `atom`), `etag`, `last_modified`, `content_hash`, `last_fetched_at`, `next_fetch_at`, `last_changed_at`, `fetch_failure_count`, `last_error`, `status`, `discovered_websub_hub`, `discovered_websub_topic`, `discovered_rsscloud_endpoint`, `created_at`.

**feed_aliases:** `id`, `feed_id`, `url` unique, `reason` (`redirect`, `discovery`, `input`). Avoid accidental cross-domain canonicalization without validation.

**feed_items:** `id`, `feed_id`, `external_id`, `external_url`, `title`, `author`, `summary_text`, `content_html_sanitized` or source content separately with safe rendering, `content_text`, `published_at`, `source_updated_at`, `first_seen_at`, `last_seen_at`, `content_hash`, `search_vector` (generated or maintained tsvector), `is_deleted` false; unique `[feed_id, external_id]`. Avoid using title/date as sole identity.

**feed_item_revisions:** `id`, `feed_item_id`, `revision_number`, `content_hash`, `payload_snapshot` (bounded JSONB or text), `recorded_at`; unique `[feed_item_id, revision_number]`. Only create on meaningful changes.

**user_feed_subscriptions:** `id`, `user_id`, `feed_id`, `folder_name` optional, `subscribed_at`, `unsubscribed_at`/active flag; unique active `[user_id, feed_id]`.

**user_inbox_events:** `id` bigint generated sequence, `user_id`, `event_type`, `feed_id`, `feed_item_id`, `document_id` nullable, `outbox_event_id`, `occurred_at`, `created_at`, lightweight JSONB metadata. Unique `(user_id, outbox_event_id)` where applicable. Cursor is bigint `id`, not timestamp.

**opml_imports:** `id`, `user_id`, `status`, `total_count`, `success_count`, `skipped_count`, `error_count`, `error_summary` bounded, timestamps. Do not retain the original uploaded file indefinitely by default.

### Publishing

**documents:** `id`, `publication_id`, `path` (normalized, unique per publication), `title`, `current_revision_number`, `visibility` (`draft`,`public`), `published_at`, `updated_at`, `deleted_at`, `rss_guid` stable UUID/URI, `content_sha256`; unique `[publication_id, path]` including tombstones to prevent accidental URL reuse.

**document_revisions:** `id`, `document_id`, `revision_number`, `markdown`, `sha256`, `created_by_user_id`, `created_at`; unique `[document_id, revision_number]`. Source bytes are authoritative. Revision append and document pointer update occur in a transaction.

### Upstream push

**upstream_push_subscriptions:** `id`, `feed_id`, `protocol` (`websub`, `rsscloud`), `hub_url`, `topic_url`, `callback_token_digest`/lookup token, encrypted `secret` where relevant, `status`, `lease_expires_at`, `last_requested_at`, `last_confirmed_at`, `next_renew_at`, `failure_count`, `last_error`, timestamps; unique active by `(feed_id, protocol, hub_url, topic_url)`.

### Downstream push

**downstream_subscriptions:** `id`, `protocol`, `topic_url`, `callback_url`, `callback_host` metadata, encrypted `secret` (WebSub only), `status` (`pending`,`active`,`expired`,`unsubscribed`), `verification_challenge_digest`, `verification_expires_at`, `lease_expires_at`, `failure_count`, timestamps; unique `(protocol, topic_url, callback_url)` with coherent re-subscribe transitions.

**delivery_attempts:** `id`, `downstream_subscription_id`, `outbox_event_id`, `attempt_number`, `status`, `http_status`, `last_error`, `next_attempt_at`, timestamps; unique `(downstream_subscription_id, outbox_event_id, attempt_number)`.

### Durable internal processing

**outbox_events:** `id` UUID, `event_type`, `aggregate_type`, `aggregate_id`, `aggregate_version`, `payload` bounded JSONB, `created_at`, `dispatched_at`, `attempts`, `last_error`; unique `(aggregate_type, aggregate_id, aggregate_version, event_type)` where applicable.

**idempotency_keys** (optional but recommended for MCP mutations): `id`, `user_id`, `operation`, `client_key`, `request_hash`, `result_reference`, `expires_at`.

**Security:** add request/audit event logging without logging credentials or document contents. Keep a small operator-visible `processing_failures` table if Sidekiq retry/dead queue visibility alone is insufficient.

### 4.1 Derived data and indexes

- PostgreSQL GIN index on `feed_items.search_vector`; index `(feed_id, published_at DESC)` and `(feed_id, first_seen_at DESC)`.
- Index `(user_id, id DESC)` on inbox events; `(user_id, feed_id)` on subscriptions.
- Index `feeds.next_fetch_at`, push lease renewal times, `outbox_events.dispatched_at`, and pending delivery retry times.
- Track feed content fingerprints independently from item fingerprints.
- All event fanout must use idempotent upserts to avoid duplicate inbox events after retries.
- If a feed has zero subscribers, reduce polling or retire upstream push after a configurable grace period; retain historical content subject to storage policy.

---

## 5. Feed discovery, ingestion, parsing, storage

### 5.1 Discovery rules

Input may be a feed URL or ordinary website URL. For HTML inputs, look for `<link rel="alternate" type="application/rss+xml">` and Atom alternatives. For feed inputs, detect format via content, not filename. Follow bounded redirects, validate every redirect target against SSRF rules, and record canonical aliases. Prefer a valid self link only after verifying it identifies the same feed. Return multiple discovered feeds if a site advertises several; do not silently choose an unrelated feed. An MCP subscribe request can return `selection_required` with choices.

### 5.2 Fetch strategy

- Prefer HTTP GET with `If-None-Match` and `If-Modified-Since` when previously provided.
- Handle 304 as unchanged; do not rewrite items or create events.
- Bounded timeouts (connect and total), redirect cap, response byte cap, decompression cap, user agent, TLS verification.
- Honor `Cache-Control` / `Retry-After` where feasible and implement jitter/backoff.
- Initial poll interval configurable (e.g., 15 minutes); adapt based on feed churn and failures. Never promise instant updates when polling only.
- Lock a feed ingestion using advisory lock or equivalent to prevent overlapping polling and push ingestion races. Release reliably on crash.
- Queue parse/normalize and persist transactionally. Do not perform external network calls inside SQL transactions.

### 5.3 Normalization rules

- Support RSS 2.0 and Atom 1.0 first; use safe XML parser, with external entities and network access disabled.
- Normalize absolute URLs, title, authors, published/updated timestamps, summary, body, stable external IDs; retain original feed URL and source permalink.
- Stable item identifier priority: Atom `id`, RSS `guid`, then normalized permalink; if all absent, deterministic fallback fingerprint with documented limitations.
- Treat changed `content_hash` for same stable ID as a revision, not a new item. Don't modify historical publication timestamps simply because fetched anew.
- Never execute feed HTML or remote scripts. Store sanitized content for UI and bounded text for search.
- Empty feed, malformed item, intermittent 500, and deleted feed must not cause destructive loss of archived items.
- External feed item content is private to the reader/archive context; publishing it to a public user URL requires a separate user action and respecting rights.

### 5.4 Search

Use PostgreSQL full-text search (`websearch_to_tsquery` or equivalent), filtering to **feeds the requesting user is authorized to access**. Inputs: `query`, optional `feed_id`, `since`, `until`, sort (`relevance`,`newest`), `limit`, `cursor`. Escape/prevent pathological queries. Default to newest where appropriate, cap page size at 100. Return short snippets and canonical links; an explicit `get_feed_item` retrieves fuller stored details. No vector search in v1.

### 5.5 Import/export OPML

Accept OPML 1.0/2.0 outlines with `xmlUrl`. Preserve folder grouping when practical. Strict XML parser (no DTD/XXE), cap upload bytes and outlines (configurable defaults: 2 MB, 2,000 feeds), dedupe and return per-item errors. Schedule work in batches. Export OPML 2.0 as user-owned feed list, preserving `xmlUrl`, title, `htmlUrl`, and folders. Import should be idempotent.

---

## 6. Shared external push subscriptions

**Decision:** One upstream protocol registration per canonical feed, not per user. Reconcile readers' active subscriptions whenever a feed changes or gets its first/last user subscription. Discovery can identify both WebSub and rssCloud. Prefer an operational WebSub registration if possible, but support both; registering both simultaneously is allowed only with deduplication and not needed for initial optimization. Keep polling as a safety net.

### 6.1 WebSub subscriber

- Discover hub/topic in HTTP `Link` headers or XML/HTML feed metadata per W3C discovery rules.
- Send `hub.mode=subscribe`, `hub.topic`, `hub.callback`, optional `hub.secret`, and requested lease.
- Provide reachable callback `GET` for `hub.challenge` verification, checking mode, topic, expected pending state and unguessable callback token.
- Accept callback `POST` content: enforce body limit, recognize `Content-Type`, verify `X-Hub-Signature` using HMAC when a secret was negotiated (constant-time compare); never process invalid signatures.
- Respond quickly and process asynchronously from a durable persisted payload or staged ingestion record. A 2xx means safely accepted for processing; don't acknowledge before durability.
- For full feed updates, ingest pushed body directly; do not refetch unnecessarily. For supported partial/delta content, apply only if safe, otherwise queue a guarded fetch.
- Renew before lease expiry with jitter; handle unsubscribe, unexpected verification, hub failures, migration and expired leases.
- Don't interpret arbitrary callback JSON as authenticated feed content merely because it references a valid topic.

### 6.2 rssCloud consumer

- Parse RSS `<cloud>` and supported `source:cloud` advertisements. Legacy XML-RPC and HTTP-POST/REST interoperability are required; SOAP is explicitly deferred unless compelling tests demand it.
- Register the shared Open.News callback using the remote server's advertised registration procedure and format. `rssCloud` short-lived subscriptions typically last approximately 25 hours: renew at least every 24 hours, with conservative margin and failure retries.
- Expose callback endpoint with unguessable token. Implement appropriate verification/challenge behavior for advertised server variants. Treat a valid ping as **a trigger to fetch** the known feed, not content.
- Reject unknown/unregistered topic URLs; apply per-feed cooldown/coalescing so duplicate pings do not cause fetch storms.
- Handle both XML-RPC and form POST callback payloads needed for interop. Keep XML secure and bounded.

### 6.3 Fallback behavior

A push registration might not work, or an upstream hub might disappear. The feed is still polled periodically and can be refreshed on demand within safe rate limits. Store current push status visibly for operations. No silent permanent starvation of updates.

---

## 7. Markdown publishing and public delivery

### 7.1 Namespace and paths

Each account owns `https://open.news/{namespace}/`. `namespace` is validated, unique and immutable in the first version (admin override later). Reserve paths such as `mcp`, `api`, `oauth`, `auth`, `admin`, `health`, `assets`, `feed.xml` where appropriate.

For example:

- `https://open.news/matt/notes/hello`
- `https://open.news/matt/feed.xml`
- `https://open.news/matt/feed.atom`
- `https://open.news/matt/notes/hello?revision=3` (optional read-only revision view; no revision mutation)

Normalize paths to reject `..`, encoded slashes, control characters, double separators, path collisions, and reserved segments. Enforce max depth and length. Client-provided path must never escape the caller's own namespace.

### 7.2 Content representations

- Store UTF-8 Markdown as the canonical source; size limit configurable (initial default 256 KB per revision).
- `Accept: text/markdown` returns the exact normalized Markdown bytes (or documented frontmatter behavior), `Content-Type: text/markdown; charset=utf-8`.
- Browser/default `Accept` returns server-rendered HTML with safe Markdown parser. **Raw HTML disabled or sanitized**, links and images filtered for dangerous schemes. Strict Content Security Policy; no user scripts/iframes.
- `Vary: Accept`; `ETag` representation-specific, `Last-Modified`, conditional 304 and sensible caching. Drafts require authorization and must not leak through public feeds/search; prefer no public response at all.
- Optional YAML frontmatter accepted only from controlled allowlist fields (`title`, `description`, `date`, `tags`). Never deserialize arbitrary YAML objects. Title/path may also be supplied as separate MCP parameters.
- Public documents are visible to anyone with URL, indexed by search engines unless configured otherwise. Provide explicit confirmation/description in agent tool results.

### 7.3 Revision and update semantics

- Creating a document creates revision 1 and `document.created` outbox event in the same transaction.
- Updating content creates a revision only if hash differs; `document.updated` event points to revision.
- Require optional `expected_revision` to prevent lost updates. Return a conflict with current revision if mismatch; no last-write-wins silent override.
- Draft -> public triggers publication. Public -> draft removes item from public generated feed and triggers relevant update. Deletion uses a tombstone and doesn't recycle the URL.
- Provide `list_documents`, `get_document` (with revision), `update_document`, `delete_document`, and `publish_document` tools. Avoid a full visual editor.

### 7.4 Generated feeds

Per publication, produce RSS 2.0 and Atom. Items expose public documents only. Stable GUID/Atom ID stays unchanged across updates. Use `pubDate`/`published` for initial publication, `updated` for revisions where format supports it, with an optional revision extension for clients that want detail. Avoid emitting duplicate items for every edit. Include valid self links and feed URLs. Support pagination or bounded recent items (e.g. 50) with explicit retention policy for feed XML; archive retains older documents.

Advertise both real-time protocols on RSS and Atom as appropriate:

- rssCloud `<cloud>` registration information and optionally supported `source:cloud`.
- WebSub `rel="hub"` and `rel="self"` links in the feed, plus `Link` headers where useful.

### 7.5 Document notifications versus WebSub topic payloads

Important distinction: WebSub content distribution for a **feed topic** must deliver the **feed resource** representation (usually RSS or Atom), not invent a JSON event or send just Markdown for that feed topic. Optionally publish a separate WebSub topic at an individual Markdown document URL and deliver full Markdown for that topic, but this is **deferred until after feed-topic conformance**. Internal inbox notifications may carry metadata/revision references independently of WebSub's wire format.

---

## 8. Outbound rssCloud cloud and WebSub hub

Scope initially limited to public feeds published by this Open.News instance. Never accept a downstream subscription for an unowned, private, or arbitrary external topic. All callbacks must pass safe-URL validation.

### 8.1 rssCloud cloud server

- Advertise the cloud from hosted RSS feeds, with interoperable endpoint formatting.
- Support REST/HTTP-POST registration and XML-RPC `pleaseNotify` compatibility; use the relevant registration method advertised in our own `<cloud>` element. SOAP deferred.
- Verify callback reachability and, where applicable, challenge response before activation. Support correct callback identity and only register verified callbacks.
- Set expiry (approximately 25 hours in rssCloud convention), and honor refresh/renewal.
- On a hosted publication feed change, enqueue a lightweight protocol-correct notification with the **feed URL**. No Markdown/JSON payload substitution.
- Accept `ping` only for hosted topics that have actually changed; reject or ignore attempts to make the hub repeatedly fetch arbitrary remote URLs. Internally generated events should drive fanout; external pings to self-hosted topics may be accepted with authorized validation.
- Log attempts, retry transient failures with exponential backoff and bounded max attempts; avoid fanout storms.

### 8.2 WebSub hub

- Expose `POST /websub/hub` handling `hub.mode=subscribe|unsubscribe`, `hub.topic`, `hub.callback`, `hub.secret` optional, and requested lease.
- Ensure topic is one of this instance's **public hosted** RSS/Atom feeds; callback URL must be public and safe.
- Verify subscriber intent via challenge to the exact callback URL; only activate after correct response. Persist pending state and expiration.
- Use finite leases; never grant perpetual subscriptions. Renew, expire, unsubscribe and re-subscribe cleanly; allow re-request of active subscriptions.
- When feed content changes, deliver the current full feed representation in the POST body with the topic's actual `Content-Type`. This is WebSub's **fat push**. Include `X-Hub-Signature` HMAC if the subscriber supplied a secret, using a recognized algorithm and correct signature encoding.
- Outbound delivery status/retries tracked; avoid serial outbound HTTP inside the document transaction or inbound requests.
- Verify each callback's DNS resolution and network addresses (including redirects) to prevent SSRF. Do not allow callback to local/private addresses, metadata endpoints, or privileged services.

### 8.3 Delivery behavior

Outbox handler produces at most one logical `publication.feed_changed` event per committed content change; multiple rapid edits may coalesce to push current feed state, but **never lose the fact a revision occurred** from stored history. Per downstream subscription, use stable event+subscription uniqueness and retry attempts. Ack 2xx, retry 429/5xx/timeouts, classify permanent 4xx, suspend after repeated failures. Use bounded concurrency and global/per-domain limits.

### 8.4 Cross-protocol interop

A hosted feed change triggers both rssCloud and WebSub subscribers. An external WebSub delivery or rssCloud ping only updates the local reader archive; it must **not** cause Open.News to pretend to be the publisher of that external feed or notify downstream readers as an unofficial public mirror. Republishing a user-authored summary is a new hosted document with its own publisher identity and attribution.

---

## 9. Durable personal-agent inbox

A normal feed reader API is pull-based. A personal agent might be disconnected for hours or days. Therefore maintain a durable user-specific stream of **new item** and **meaningful item revision** events for feeds to which the user was subscribed at the event's occurrence.

- Event cursor is monotonically increasing `user_inbox_events.id`.
- `get_updates({after_cursor, limit, feed_id?})` returns events in ascending cursor order, a `next_cursor`, and `has_more`.
- Events contain enough item metadata and small bounded excerpts to be useful without another request; `get_feed_item` returns full retained item details. A `include_content` option may return bounded stored content in each event with strict response-size limits.
- No claim of proactive wake-up for agents unless a specific supported push integration exists. Polling `get_updates` is sufficient for MVP; optional webhook delivery to an authenticated user endpoint is a future feature distinct from feed protocol callbacks.
- If an item is revised, notify users with `feed_item.updated` instead of duplicating the item as new.
- Avoid cross-user data leakage in inbox materialization. On unsubscribe, existing inbox history stays (unless user requests deletion), but no new feed events are generated for that user.
- Define retention: inbox records retained at least 90 days initially (configurable); item archive continues independently. Return a structured `cursor_expired`/resync instruction if older cursors have been purged.

---

## 10. Remote MCP interface and authentication

### 10.1 Protocol and OAuth

Implement MCP using an up-to-date maintained Ruby implementation or a small explicit JSON-RPC transport layer adhering to the then-current **MCP Streamable HTTP** requirements. Do **not** copy an obsolete SSE/session transport template. Expose `/mcp` over HTTPS. Validate the `Origin` header where applicable. Use current MCP authorization discovery via OAuth Protected Resource Metadata, Authorization Server Metadata/OpenID discovery, secure authorization code with PKCE, and standards-based consent.

**Research note (as of Nov 2026):** MCP 2026-07-28 Streamable HTTP describes one POST per JSON-RPC message with optional response-scoped SSE, and no protocol-level GET stream/sessions. Implementation must choose the current supported version based on SDK/client interoperability tests, rather than hardcoding an earlier transport. See references.

OAuth scopes:

- `feeds:read` — subscriptions, items, search, inbox.
- `feeds:write` — subscribe/unsubscribe, OPML import.
- `documents:read` — own draft/private document access and management listing.
- `documents:write` — create/update/delete owned documents.

Public document URLs and hosted feeds require no OAuth. Enforce scopes on every MCP tool and on REST endpoints used by the same operations.

### 10.2 Initial MCP tools

Use names and parameter schemas as below; return structured content (JSON-compatible) with stable IDs, pagination cursors, canonical URLs, and explicit errors. Avoid returning unbounded XML/text payloads in one response.

| Tool | Parameters | Behavior |
|---|---|---|
| `subscribe_feed` | `url`, `folder?` | Discover/feed subscribe, idempotent, queue initial fetch; if ambiguous return choices. |
| `unsubscribe_feed` | `feed_id` | Remove only caller's subscription. |
| `list_subscriptions` | `cursor?`, `limit?` | Return subscriptions and feed status. |
| `list_feed_items` | `feed_id?`, `since?`, `until?`, `cursor?`, `limit?` | Newest items among authorized feeds. |
| `get_feed_item` | `item_id` | Return stored item detail and source metadata. |
| `search_items` | `query`, `feed_id?`, `since?`, `until?`, `sort?`, `cursor?`, `limit?` | PostgreSQL full-text search across caller's subscriptions. |
| `get_updates` | `after_cursor?`, `limit?`, `include_content?` | Durable per-user inbox with monotonic cursor. |
| `import_opml` | `opml_xml` | Validate bounded OPML and enqueue import; return import job ID/status. |
| `export_opml` | none | Return OPML (bounded), or safe authenticated export URL for larger results. |
| `publish_document` | `path`, `markdown`, `title?`, `visibility?`, `idempotency_key?` | Create document in caller's namespace and return URL/revision. |
| `get_document` | `path`, `revision?` | Read caller-owned document incl. drafts; public URL is also available. |
| `update_document` | `path`, `markdown`, `expected_revision?`, `title?`, `visibility?`, `idempotency_key?` | Revision-aware update; conflict on stale revision. |
| `list_documents` | `cursor?`, `limit?`, `visibility?` | List caller's documents. |
| `delete_document` | `path`, `expected_revision?` | Soft-delete/tombstone; explicit destructive action. |

Implement `get_opml_import_status(import_id)` if import is asynchronous; alternatively an explicit `get_job_status(id)` for known user-owned operations. Do not expose arbitrary Sidekiq job IDs.

### 10.3 Tool behavior guidelines

- Describe exactly what will be public in the publishing tool. Default `visibility` to `draft` unless explicitly requested public; **do not accidentally publish private agent context**.
- Return actionable errors: `invalid_url`, `feed_not_found`, `ambiguous_feed`, `already_subscribed`, `rate_limited`, `revision_conflict`, `forbidden`, `cursor_expired`.
- Authenticate all operations as account/user, not as a free-standing globally trusted agent.
- Write tools audit actor, scope, and resource ID. Idempotency keys prevent retries from publishing duplicate documents.
- Favor concise tool descriptions with honest behavior; don't promise continuous spontaneous notification to MCP clients.

---

## 11. HTTP endpoints (proposed)

Routes are illustrative; settle exact route names in code and docs without needlessly changing public URL contracts.

**Public resources**

```text
GET  /:namespace/:path                         public HTML/Markdown (Accept negotiation)
GET  /:namespace/feed.xml                      public RSS 2.0
GET  /:namespace/feed.atom                     public Atom
GET  /health/live                             process health
GET  /health/ready                            DB/queue dependencies health
```

**MCP and OAuth**

```text
POST /mcp
GET  /.well-known/oauth-protected-resource   or appropriate resource-specific metadata URI
GET  /.well-known/oauth-authorization-server  or RFC 8414 equivalent
GET/POST auth/authorize, token, revoke, etc. (implementation-defined)
```

**Push protocol ingress/egress**

```text
GET  /callbacks/websub/:token                   upstream intent challenge
POST /callbacks/websub/:token                   upstream content delivery
GET  /callbacks/rsscloud/:token                 upstream challenge
POST /callbacks/rsscloud/:token                 upstream lightweight notification
POST /websub/hub                                downstream subscription control
POST /rsscloud/pleaseNotify                     downstream cloud registration (REST)
POST /rsscloud/RPC2                             downstream XML-RPC registration
POST /rsscloud/ping                             hosted feed change ping (guarded)
```

Add minimal HTML pages for login, OAuth consent, dashboard, feed subscription status, documents, imports, and admin operations. Do not create a SPA framework unless required.

---

## 12. Transactional outbox and Sidekiq processing

### 12.1 Required event types

```text
feed_item.created
feed_item.updated
document.created
document.updated
document.published
document.unpublished
document.deleted
publication.feed_changed
upstream_subscription.renewal_due
```

Publishing event and document revision must commit atomically. Ingestion and feed item changes must commit atomically with outbox rows. A scheduler reads unprocessed outbox entries with row locks/`SKIP LOCKED`, enqueues Sidekiq jobs, and records dispatch progress. A recovery sweeper re-enqueues stuck items. To avoid the enqueue/mark race, workers perform idempotent work keyed by durable outbox ID and dispatcher may enqueue duplicates; don't mark events irrevocably complete until processing state is safely recorded.

### 12.2 Suggested job taxonomy

```text
Feeds::DiscoverJob
Feeds::FetchJob
Feeds::IngestPayloadJob
Feeds::ScheduleDueJob
Push::RegisterUpstreamJob
Push::RenewUpstreamJob
Push::AcceptWebSubPayloadJob
Publishing::RefreshFeedJob
Events::DispatchOutboxJob
Events::MaterializeInboxJob
RssCloud::DeliverPingJob
WebSub::DeliverContentJob
Delivery::RetryDueJob
Opml::ImportJob
Maintenance::ExpireLeasesJob
Maintenance::PurgeExpiredInboxJob
```

Queues: `critical_callbacks`, `ingestion`, `fanout`, `scheduled`, `maintenance`, `default`, with bounded concurrency and per-host rate limits. Keep callback processing fast: validation + durable staging, then work in jobs. All external HTTP is retried only when safe. Use structured logs keyed by request, feed, subscription, outbox event, and delivery IDs.

### 12.3 Recovery

If Redis loses queued jobs, PostgreSQL outbox and due-work tables must allow rescheduling. On deploy/restart, run catch-up sweeps for due feed fetches, expired/upcoming leases, unsent outbox events, and failed delivery attempts. A killed worker should not cause a document notification to disappear.

---

## 13. Security and abuse resistance (release blockers)

1. **SSRF:** Validate all URLs at ingestion, discovery, WebSub hubs, rssCloud endpoints, callbacks, redirects, and delivery. Allow only intended HTTP(S), reject loopback, private/link-local/reserved IPs, IPv6 local ranges, cloud metadata addresses, mixed DNS rebinding; revalidate resolved address at connection, and all redirects. If the HTTP client cannot safely pin DNS resolution, restrict/replace it.
2. **Untrusted input:** Limit feed bytes, decompressed bytes, XML depth/entity expansion, OPML outlines, Markdown document bytes, HTTP headers, callback payload, string lengths, and response output. No shelling out based on user content.
3. **Callback verification:** Validate topic/token/mode/challenge; strong random tokens; constant-time HMAC comparisons. Invalid WebSub push must never be ingested.
4. **Authorization:** Every user-scoped query and document mutation checks ownership. OAuth least privilege, PKCE, redirect URI validation, token revocation, no open redirect.
5. **Publishing abuse:** Per-account quotas (document count, storage, publish rates), rate limits, moderation/removal ability, spam handling, robots/site policy, abuse reporting contact. Don't allow arbitrary JavaScript hosting.
6. **HTML/XSS:** Sanitize external feed HTML and rendered Markdown. Raw HTML off by default, strict CSP, no executable event-handler attributes or dangerous URL schemes. Never render untrusted RSS HTML unsanitized in admin.
7. **Webhook amplification:** Rate limit inbound pings and callbacks, coalesce refetches, cap downstream fanout, per-origin queue concurrency, retries with backoff, prevent subscription to arbitrary third-party topic URLs as a hub.
8. **Secrets:** OAuth credentials and WebSub shared secrets encrypted at rest; redacted logs; HTTPS everywhere; secure cookies; dependency advisories.
9. **Deletion:** Account erasure process, document tombstones, private drafts removed from public delivery, user-specific subscription and inbox deletion policies.
10. **Visibility:** Public publishing is opt-in and explicit in agent tool descriptions; reader archive is not public by default.

---

## 14. Operational characteristics

### 14.1 Initial capacity targets (engineering assumptions, not promises)

Aim for one small VPS handling roughly 1,000 active users, 10,000 distinct feeds, and hundreds of thousands to a few million retained items, depending on average item sizes and fetch cadence. These are **test targets**, not validated production benchmarks. Instrument before optimizing. Keep bounded retention, optional partitioning by time only after evidence suggests need.

### 14.2 Metrics

- Active users / OAuth clients, feeds, user subscriptions, hosted documents.
- Feed fetch successes/errors/304s; bytes ingested; ingest lag; item creation/update rates.
- Upstream WebSub/rssCloud registration status, renew failures, valid/invalid callbacks, push-to-ingest latency.
- Downstream WebSub/rssCloud subscribers, delivery success %, latency, retries, expired leases, dead destinations.
- Outbox backlog/oldest age, Sidekiq queue latency, duplicate events prevented.
- MCP call counts/durations/errors, search query latency, OPML import outcomes.
- PostgreSQL size/growth, per-user storage, Redis/Sidekiq health.

### 14.3 Configuration / deploy

Provide `.env.example`, `Dockerfile`, optional Docker Compose with web/worker/postgres/redis for development, and production deployment instructions for Ubuntu/DigitalOcean with Nginx, TLS, Puma, Sidekiq under systemd. External callbacks require publicly reachable HTTPS and stable origin. Store `APP_BASE_URL`, trusted proxy headers, OAuth issuer, encryption keys, DB URL, Redis URL, limits, and polling settings in environment/config. Avoid hardcoding `open.news` in logic so self-hosted instances work.

Backups: PostgreSQL dumps/PITR strategy, credentials/encryption keys, restore drill instructions. Store no unique authoritative data only in Redis. Migrations must be reversible where practical.

### 14.4 License and docs

Select an OSI-approved license in repository setup (MIT or Apache-2.0 reasonable; confirm preference if needed). Provide architecture overview, API/MCP tool catalog, setup, protocol interop notes, deployment, security model, and troubleshooting. Published content belongs to its authors; software license does not imply a license grant over published material.

---

## 15. Testing and interoperability plan

Use RSpec or Rails Minitest consistently. Test core services without live network, with HTTP fixtures for real feed patterns. Exercise protocol behavior using local mock servers and integration tests. CI runs unit, request, service, security, and schema tests.

### Parsing and storage

- RSS 2.0 and Atom feeds, namespace variants, missing GUIDs, Unicode, relative links, same GUID changed body, out-of-order dates.
- Conditional GET 304, redirect, bad XML, enormous XML, duplicate feed subscription, 500/backoff.
- Multiple users on one feed result in one upstream fetch and independent authorization/inbox cursor.
- Search never returns feed items from a feed the user doesn't subscribe to.
- OPML import, duplicate outlines, invalid XML, XXE attack, export/import round trip.

### WebSub

- Discovery via Link headers/feed metadata, subscribe and unsubscribe confirmation, lease renewal/expiry.
- Signed SHA-256 distribution accepted; bad signature and missing required signature rejected.
- Pushed full RSS/Atom ingested without redundant fetch; content-type mismatch and malformed payload fail safely.
- Hub verifies arbitrary subscriber callbacks before activation, refuses non-owned topics, respects finite leases, delivers full feed with correct content-type and signature.
- Duplicate deliveries do not create duplicate items/events.

### rssCloud

- Parse original `<cloud>` and `source:cloud`, XML-RPC and REST compatibility.
- Consumer registers and renews within convention, responds to callback challenge, refetches once despite repeated pings.
- Cloud verifies callback and sends feed URL ping; registration expires and re-registration works.
- Malicious pings never trigger arbitrary fetches, and callbacks do not reach internal network.

### Publishing

- New Markdown public URL returns Markdown or HTML by Accept; different ETags where representations differ; correct Vary.
- Draft inaccessible publicly; update revision conflicts; stable feed GUID after edit; deletion/tombstone behavior; no arbitrary HTML script execution.
- One update fans out to all applicable push protocols and inbox events once logically even when Sidekiq retries.

### MCP and OAuth

- OAuth discovery, PKCE and auth code, scoped access, revocation, cross-user isolation, invalid token, protocol-version compatibility.
- Tool schema validation, pagination/cursors, bounded content, expected revision, idempotent publication retries.
- Explicit compatibility smoke test with at least one target Dot client and one independent MCP client before calling v1 complete.

### Reliability

- Kill worker between database commit and enqueue, restore and verify outbox recovery.
- Simulate hub outage, callback timeout, renewed leases, Redis restart, duplicate WebSub push, repeated rssCloud ping.
- Downstream destination 429/500 -> bounded retries with logs; 410 -> disable/cleanup as policy.

---

## 16. Implementation phases and acceptance gates

**Build one Rails app incrementally. Each phase requires tests, seed/demo script, migration, and documented API surface before moving to the next.** No architecture rewrite between phases without a written reason and failing requirement.

### Phase 0 — Foundation

- Fresh Rails 8 project, PostgreSQL, Sidekiq/Redis, account/login, namespace, test harness, CI, configuration and secure outbound HTTP fetcher.
- Schema baseline, UUID entities, transactional outbox skeleton, health endpoints.
- **Gate:** one-command local boot, account creation, jobs processed, database and queue recovery documented.

### Phase 1 — Agent-native feed reader (first usable MVP)

- Feeds discovery/ingestion, shared feed/item tables, polling and dedupe, full-text search, per-user subscriptions and inbox cursor.
- OAuth + MCP with `subscribe_feed`, `unsubscribe_feed`, `list_subscriptions`, `list_feed_items`, `get_feed_item`, `search_items`, `get_updates`.
- OPML import/export and minimal operator/user UI.
- **Gate:** user connects agent, imports 20 feeds, searches history, sees new items, and another user shares same upstream fetch without data leakage.

### Phase 2 — Upstream real-time ingestion

- WebSub subscriber then rssCloud consumer, advertised hub discovery, registration verification, lease renewal, secure callbacks, signatures, dedupe and poll fallback.
- **Gate:** test publisher pushes full WebSub feed without follow-up fetch; rssCloud update triggers guarded fetch; restarts do not lose subscriptions.

### Phase 3 — Markdown publishing

- Documents/revisions, public URL with Markdown/HTML representations, draft/public flow, stable RSS/Atom feeds, MCP publishing tools.
- **Gate:** agent creates/edits a public document; two normal non-MCP readers can subscribe to hosted RSS/Atom; permanent URL and revision checks work.

### Phase 4 — Downstream real-time syndication

- WebSub hub and rssCloud cloud server for hosted feeds; callback verification, finite leases, full feed delivery, HMAC, lightweight pings, retry status dashboard.
- **Gate:** two independent external test subscribers, one WebSub and one rssCloud, receive the same publication change correctly and recover after simulated delivery failure.

### Phase 5 — Hardening and release

- Load/abuse tests, storage quotas, moderation hooks, operator metrics, deployment/backup guide, independent protocol conformance passes, security review.
- **Gate:** fresh self-hosted installation can run entire reader/publisher protocol demonstration from documentation; public hosted Open.News instance is operational.

**Avoid prematurely building all phases simultaneously.** Design migration boundaries now, implement incremental vertical slices.

---

## 17. Prioritized initial coding-agent task list

1. Bootstrap Rails application with Postgres/Sidekiq and automated tests; add `README`, `.env.example`, `docker-compose.yml` for development.
2. Write migrations/models for users, feeds, feed aliases, items, revisions, user subscriptions, inbox events, outbox events, publications, documents and document revisions. Add push tables when implementing Phase 2/4.
3. Implement safe fetch service and tests for SSRF, redirect, timeouts, payload limits.
4. Implement RSS/Atom discovery/parse/normalize/ingest with idempotent item deduplication and outbox events.
5. Implement polling jobs, shared feed scheduling and conditional requests.
6. Implement user subscription services, inbox materialization and PostgreSQL search.
7. Implement minimal web account/dashboard and a working standards-compliant OAuth/MCP connection with read tools.
8. Add OPML import/export.
9. **Stop and demonstrate Phase 1**. Do not code a WebSub hub while feed reader basics remain unproven.
10. Implement the remaining phases in specified order, with conformance fixtures and integration smoke tests.

### Demo script for the finished system

```text
User A: Connect a personal agent to Open.News.
Agent: Import this OPML and subscribe to a new RSS feed.
External publisher: Publish a new RSS/Atom item and send WebSub/r​​ssCloud notification.
Agent: Read latest updates and search all previously ingested subscribed content.
User A: Publish this Markdown briefing at /briefings/today.
System: Serve Markdown/HTML at stable HTTPS URL and updated RSS/Atom feed.
External WebSub subscriber: Receive full updated feed as signed push.
External rssCloud subscriber: Receive lightweight ping containing feed URL.
User B: Subscribe to A's generated feed using a normal reader.
Result: All four external interoperability modes work, and every user sees only authorized data.
```

---

## 18. Decisions deferred, with safe defaults

| Question | Default for implementation | Later option |
|---|---|---|
| Custom domains | Not in v1; namespace under application domain | Domain verification + TLS + URL migration/redirect policy |
| Additional publications per user | One default publication | Multiple named publications |
| Document-level direct WebSub | Feed topics only | Markdown document as separate `text/markdown` WebSub topic |
| General-purpose WebSub hub for third-party topics | Not offered | Independent hub product if market demand appears |
| SOAP rssCloud | Deferred | Implement on proven interop demand |
| External feed article extraction | Feed-contained content only | Respectful fetch/extract with publisher policy |
| Semantic search | PostgreSQL lexical search | Optional vector backend if measurable need |
| Real-time agent wakeups | Durable inbox + polling | Supported agent-platform webhooks/notifications |
| Paid plans | None | Per-account storage/ingest quotas and billing |
| Per-user private published pages | Draft vs public only | Tokenized/private resource access |
| Browser UI | Minimal admin and account management | More polished reading/writing experience |
| Content rendering | Basic safe Markdown | Templates/themes when demand appears |

---

## 19. External protocol and implementation references

These are references for the coding agent, not substitutes for tests or current standards verification.

- **W3C WebSub Recommendation:** https://www.w3.org/TR/websub/ — discovery, subscriber callbacks, hub verification, leases, content distribution and HMAC.
- **rssCloud API (RSS Advisory Board):** https://www.rssboard.org/rsscloud-interface — registration parameters, notification model, 25-hour expiry/24-hour renewal convention.
- **RSS 2.0 spec:** https://www.rssboard.org/rss-specification — including `<cloud>` element.
- **rssCloud reference server docs:** https://rpc.rsscloud.io/docs — combined rssCloud and WebSub examples, REST + XML-RPC, cross-protocol fanout.
- **MCP current specification:** https://modelcontextprotocol.io/specification — validate remote HTTP transport and authorization against chosen official version.
- **MCP Streamable HTTP 2026-07-28:** https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2026-07-28/basic/transports/streamable-http.mdx
- **MCP authorization 2026-07-28:** https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2026-07-28/basic/authorization/index.mdx
- **Sidekiq:** https://github.com/sidekiq/sidekiq — Redis-backed job execution and version requirements.

### Nonnegotiable final reminder

Open.News is **not** a general message broker. Its primary model is **feeds, documents, subscriptions, and interoperable delivery**. Avoid reintroducing arbitrary agent channels simply because the prior project supported them. The product should stand on its own as an excellent RSS/Atom reader and minimal Markdown publisher, whether the caller is a personal agent or an ordinary web client.
