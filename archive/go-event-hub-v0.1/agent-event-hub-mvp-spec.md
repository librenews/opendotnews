# Agent Event Hub — MVP Engineering Specification

**Status:** Implementation-ready proposal, v0.1  
**Date:** 2026-11-21  
**Working name:** Agent Event Hub (`agenthub` in examples; not a brand decision)  
**Primary language:** Go  
**Event backend:** NATS JetStream  
**License recommendation:** Apache-2.0

## 1. Product statement

Agent Event Hub is a small, open-source, embeddable, self-hostable publish/subscribe service for agents. A publisher broadcasts an arbitrary payload to a namespaced channel. A subscriber registers a delivery endpoint and automatically receives newly published events. JetStream retains events for bounded replay and retry after interruptions.

**The hub is dumb by design.** It does not inspect payload schemas, classify content, use an LLM, interpret event types, recommend channels, orchestrate workflows, or run subscribers' agents. The receiving application chooses what to do.

**Guiding promise:** “Claim a namespace, connect your agent, and publish or subscribe to channels. The hub handles delivery.”

## 2. Goals and non-goals

### Goals (v0.1)

1. Ship a standalone Go executable, Docker image, and importable Go package.
2. Support a locally embedded NATS server with persistent JetStream storage for easy single-binary deployment, and an external NATS connection for production.
3. Expose exactly three user-facing MCP tools: `publish`, `subscribe`, `unsubscribe`.
4. Offer OAuth-based connection to a hosted service; also support a minimal local development/auth mode.
5. Assign each account a unique, case-insensitive namespace. Channels are owned by a namespace.
6. Treat message payloads as opaque, bounded bytes, with an optional content type.
7. Provide push delivery via authenticated HTTPS webhooks; provide live stream delivery for compatible clients, with a well-defined adapter boundary for MCP-native notifications.
8. Provide time-limited retention, retry after failure, and documented at-least-once transport semantics.
9. Keep state, configuration, and operational behavior explicit and observable.
10. Allow future federation and alternative brokers without complicating the MVP.

### Non-goals (v0.1)

- Federation, cross-hub subscriptions, NATS leaf-node integration between hubs.
- Agent discovery, social graphs, follow recommendations, channel directories, search.
- Global event type registry, schema enforcement, content moderation by LLM.
- User-facing inbox, chat history, conversation management, or agent execution.
- Guaranteed awakening of an arbitrary hosted LLM agent; its host must implement a receiver.
- Exactly-once agent actions or unlimited replay.
- Browser/mobile push notifications.
- Queue/work-distribution semantics across several agents; each subscription gets its own event copy.
- Payments, billing, analytics dashboards, multi-region HA in v0.1.

## 3. Architecture

```text
     MCP clients / API callers
                |
      OAuth / token validation
                |
       Go hub HTTP service
       +-------------------+
       | Namespace ACL     |
       | 3 MCP tools       |
       | Subscription API  |
       | Delivery adapters |
       +-------------------+
          |            |
   Metadata store    NATS JetStream
   (SQLite MVP)     (events + cursors)
          |            |
          +---- Delivery workers ----> HTTPS webhook receiver
                       |
                       +-------------> live streaming receiver
                                          (where supported)
```

- **Go server:** Go standard `net/http` where practical; use stable, maintained MCP and OAuth libraries rather than hand-writing a protocol stack.
- **Broker:** `github.com/nats-io/nats.go/jetstream`. A single JetStream stream captures multiple subject patterns; do not create one stream per public channel.
- **Embedded mode:** Start NATS using the public Go `github.com/nats-io/nats-server/v2/server` package, with an explicitly configured persistent storage directory. Validate exact embedded-server lifecycle against the pinned NATS version.
- **External mode:** Connect to a separately managed NATS installation. Never expose the internal broker port to untrusted users by default.
- **Metadata:** SQLite with WAL for single-node deployments; hide it behind a small Store interface so PostgreSQL may be introduced later. SQLite is not the distributed multi-node control-plane solution.
- **Delivery:** A bounded worker pool processes independent durable JetStream consumers and invokes configured destination adapters; end-to-end delivery is **at least once** within retention and retry limits.

### Packaging and repository structure

```text
cmd/agenthub/             # serve, init, admin CLI
pkg/agenthub/             # public embeddable library API
internal/broker/nats/     # JetStream implementation
internal/store/sqlite/    # account/subscription metadata
internal/auth/            # OAuth verification and local tokens
internal/mcp/             # tools + optional resource adapter
internal/delivery/        # webhook, streaming, retry workers
internal/httpapi/         # health/admin/API routes
internal/embeddednats/    # optional embedded broker lifecycle
configs/                 # example configurations
deploy/                  # Docker Compose and service examples
examples/                # Go publisher and webhook receiver
```

Avoid a global singleton. The library should expose `New(Config, Dependencies)`, `Start(ctx)` and `Shutdown(ctx)` (exact exported API can be idiomatic Go). Dependencies include Broker, Store, TokenVerifier, and DeliveryAdapter interfaces. Do not put auth, channel validation, retry logic, or message encoding in a large central handler.

## 4. Identity and namespace rules

**Human/account ownership:** A person or organization registers/authorizes via OAuth. Multiple connected agents can act under the same account, subject to token scopes.

**Canonical public channel:** `@namespace/channel/path`, for example `@opennews/stamford/zoning`.

Rules:

- Namespace: 3–32 ASCII lowercase characters, `[a-z0-9][a-z0-9_-]*`; canonicalize input to lowercase; uniqueness enforced by the metadata database.
- Channel path: 1–128 bytes; one or more `/`-separated segments; permit ASCII letters, numbers, `_`, `-`, `.`; reject empty segments, `..`, controls, and ambiguously encoded strings.
- Namespace ownership permits publishing to channels in that namespace. A publisher can create a channel implicitly on first successful publish.
- All channels are public to subscribe to **in v0.1**; publish requires `events:publish` plus namespace ownership. Private subscriptions and channel ACLs are deferred, but names and auth model must not preclude them.
- No wildcards in published channel names. Subscription wildcards are out of scope for v0.1.
- Reserve system namespaces (`system`, `admin`, etc.).
- The hub may use opaque internal IDs and hash/encode each canonical channel to a safe NATS subject. **Do not pass untrusted channel names directly as NATS subjects**; `/`, `.`, `*`, and `>` have different meanings in public and NATS naming systems.
- A mapping can be `ev.<opaque namespace id>.<opaque channel id>`; persist mapping, with a unique constraint on the canonical public channel.
- Future cross-hub address form (not implemented): `@namespace@hub.example/channel/path`. A local-only instance must reject remote channels as unsupported rather than silently treating them as local.

### Payloads

Payload is an opaque UTF-8 string or base64-encoded bytes plus `content_type` (default `application/json` only for JSON-value convenience; otherwise `application/octet-stream`). The service must preserve the exact content bytes and specified media type. Neither the broker nor hub is allowed to parse/transform payload semantics. Transport headers and envelope metadata are separate from the original payload.

Proposed initial maximum payload: **64 KiB** including encoded transport overhead. Configurable server limit, capped by broker limits. Reject oversize payloads before publishing.

## 5. Three MCP tools

These are the only **domain-action tools** in the first version. MCP protocol lifecycle/authorization endpoints are additional infrastructure, not extra domain tools.

### `publish`

Input:

```json
{
  "channel": "@opennews/stamford/zoning",
  "payload": {"url": "https://example.org/agenda/42"},
  "content_type": "application/json",
  "idempotency_key": "optional-client-event-id"
}
```

The implementation may accept JSON payload values through MCP and serialize them once, plus a text/base64 alternative for arbitrary content. Specify exact byte-preservation behavior in wire tests. No required `type` field. `idempotency_key` maps to a broker deduplication header for a configured short window; it is not indefinite deduplication.

Output:

```json
{
  "event_id": "01JEXAMPLEEVENTID",
  "channel": "@opennews/stamford/zoning",
  "accepted_at": "2026-11-21T17:00:00Z",
  "status": "stored"
}
```

Return success only after JetStream publish acknowledgment. Public `event_id` is an opaque stable identifier; expose internal stream sequence separately where needed, rather than confusing one stream's sequence with a channel-global sequence. Store the canonical channel in event metadata.

### `subscribe`

Input:

```json
{
  "channel": "@opennews/stamford/zoning",
  "delivery": {
    "mode": "webhook",
    "url": "https://receiver.example/agent-events"
  },
  "start_at": "new"
}
```

- `mode=webhook` is required and fully supported in v0.1.
- `mode=stream` may be provided via a separately established long-lived connection, for compatible hosts; prioritize webhook as the interoperability baseline.
- `mode=mcp` is **capability-gated** and MUST NOT be advertised unless implemented and interoperable with the pinned MCP specification and the target host. Do not assume an MCP tool call can persist an arbitrary background notification stream.
- `start_at` defaults to `new`; optionally support `earliest_available` or a valid retained cursor. Define gap/expired-cursor behavior explicitly.
- Return a stable `subscription_id`, effective delivery mode, and retention summary.
- Repeating the same subscription request should be idempotent or return the existing subscription; changing destination requires explicit verified update/replacement rather than silently swapping recipients.
- Authorization: subscriber can only create a subscription bound to its own account/token; no arbitrary impersonation.

Example result:

```json
{
  "subscription_id": "sub_01EXAMPLE",
  "channel": "@opennews/stamford/zoning",
  "mode": "webhook",
  "status": "active"
}
```

### `unsubscribe`

Input: `{ "subscription_id": "sub_01EXAMPLE" }`.

Return: `{ "status": "unsubscribed" }` (idempotent). Cancel future delivery and delete/retire the corresponding durable consumer; an in-flight webhook may still arrive, and that possibility must be documented.

## 6. Delivery contract

### Event envelope

The hub adds **only transport metadata**, leaving `payload` untouched:

```json
{
  "event_id": "01JEXAMPLEEVENTID",
  "channel": "@opennews/stamford/zoning",
  "published_at": "2026-11-21T17:00:00Z",
  "content_type": "application/json",
  "payload": {"url": "https://example.org/agenda/42"}
}
```

For arbitrary non-JSON bytes, use an explicit base64 encoding field and `content_type`. Keep a stable versioned envelope such as `envelope_version: 1`; the wrapper is a transport contract, not a semantic event schema.

### HTTPS webhook

- Delivery: HTTP POST; TLS required except for explicit development mode.
- Authentication: per-subscription generated signing secret; sign raw request bytes with HMAC-SHA256. Include delivery timestamp, event ID, subscription ID, key ID, and signature headers. Receiver checks signature and bounded timestamp skew. Support key rotation.
- Receiver returns any 2xx to acknowledge transport acceptance. A 2xx means **the receiver accepted the event**, not necessarily that its agent processed it.
- Retries for network errors, timeouts, 408, 429, and 5xx with exponential backoff + jitter. Honor bounded `Retry-After` when reasonable.
- 401/403 or persistent 4xx: mark delivery unhealthy, pause after a bounded retry policy, report failure observably; do not infinite-loop a bad endpoint.
- Max attempts and maximum retry age configurable; failed subscriptions appear in admin diagnostics.
- One subscription sees events in publication order under normal operation. At-least-once retries can cause duplicates; recommend receiver idempotency keyed by `(subscription_id, event_id)`.
- Backpressure: bounded worker queues, per-endpoint concurrency limits, and capped in-flight deliveries. A slow receiver must not block other subscribers.
- SSRF defense: reject localhost, RFC1918, link-local, cloud metadata and reserved IP destinations by default on public hosted instances, including DNS rebinding and redirect chains; re-resolve/check addresses at connect time, disallow redirects by default. Self-hosted admins may explicitly enable private destinations.
- Verify webhook ownership with a challenge handshake before activation; never send private account info to an unverified URL.

### Live subscriptions and MCP

The HTTP service can expose a streaming adapter (SSE or WebSocket) to client applications that keep a connection open. A live connection does not itself guarantee that a third-party agent host will wake its LLM; that host must implement notification handling.

For MCP, consult and pin the **2026-07-28 specification** before implementation. It includes a `subscriptions/listen` pattern for certain server-to-client notifications, but that is **not** a generic arbitrary event push guarantee. If resources are exposed, a channel may be represented as a resource and a notification can signal change, with the event fetched using a documented resource read path. Do not claim universal MCP push until tested with real clients. If direct MCP event delivery cannot be implemented cleanly, ship webhook push first and clearly document MCP limitations.

### Event history, gaps, and cursor semantics

- Use JetStream **Limits** retention, never WorkQueue retention for broadcast fan-out (work queues are not the desired semantics).
- Default event max age: **7 days**; configurable max bytes and max messages per stream/subject, with documented first-limit-wins behavior.
- A subscription starts at `new` unless requested otherwise. Every subscription must have independent progress. Create a durable filtered consumer (or another tested equivalent) per subscription initially; document resource ceilings and benchmark limits. Do not share a consumer among independent subscribers, which would load-balance events instead of broadcasting them.
- Acknowledge the broker delivery **after** receiving a successful webhook 2xx / successful receiver handoff, never before.
- On restart, workers reconnect to durable consumers and resume undelivered events.
- If event retention removes data before it can be delivered, record and expose a **gap/expired** condition. This service does not promise recovery beyond retention.
- Make delivery retries bounded and expose a dead-letter/failure diagnostic record; do not silently drop after exhausting retries.
- JetStream sequence IDs are stream-relative and may not be consecutive within a channel. Do not implement naive `seq + 1` per-channel cursor logic.
- Track publication outcome separately from delivery outcome; a successful `publish` does not mean that any subscriber received the event.

## 7. Authentication, OAuth, and authorization

### Hosted mode

1. User opens a minimal registration/claim page.
2. User authenticates with a supported OpenID Connect/OAuth identity provider or via a compliant built-in authorization server implementation.
3. User claims a unique namespace.
4. MCP client uses the MCP HTTP authorization flow with authorization-code + PKCE where applicable.
5. Hub validates bearer token issuer, audience, expiry, scopes and account/namespace mapping on every call.

**Do not confuse social login with MCP resource-server authorization.** A Google/GitHub login can establish the user account, but remote MCP authorization must independently follow the applicable MCP OAuth protected-resource and authorization-server metadata rules. An external IdP may be used for human identity; the hub still needs an appropriate OAuth authorization architecture for clients.

Proposed scopes:

- `events:publish`: publish under namespaces controlled by account.
- `subscriptions:write`: create/delete own subscriptions.
- `subscriptions:read`: inspect own subscription state when admin/API operations require it.

Use least privilege; separate CLI admin credentials from user OAuth tokens. Revoke tokens/credentials and shut down subscriptions when accounts are disabled.

### Self-hosted and embedded mode

- `auth.mode=local`: explicitly configured local tokens for development/private deployments; never enabled without operator intent on a publicly reachable listener.
- `auth.mode=oauth`: use a documented OAuth provider/authorization server.
- `auth.mode=disabled`: only on loopback by default; reject non-loopback binding unless a dangerous override is explicitly supplied.

## 8. Persistent metadata

SQLite schema (illustrative; migrations required):

```text
accounts(id, external_subject, created_at, status)
namespaces(id, account_id, canonical_name UNIQUE, created_at)
channels(id, namespace_id, canonical_path, created_at,
         UNIQUE(namespace_id, canonical_path))
subscriptions(id, account_id, channel_id, delivery_mode, endpoint,
              signing_key_ref, durable_consumer, status,
              created_at, updated_at, last_success_at, last_error)
delivery_failures(id, subscription_id, event_id, failure_category,
                  attempts, recorded_at)
```

Keep secrets out of event payloads and routine logs. Encrypt webhook signing secrets at rest or store them through a configurable secret provider. Back up SQLite metadata **and** JetStream state together with documented recovery expectations. Store metadata independently from JetStream so a broker rebuild does not reassign ownership.

Subscription creation must be transactionally reconciled with durable consumer creation: write a provisioning state, create the consumer idempotently, then activate; recover interrupted provisioning on startup. Similarly reconcile deletion. Document crash consistency explicitly.

## 9. Broker strategy

**Initial choice: one shared persistent stream for all app events with a controlled `ev.>` subject pattern**, plus durable filtered consumers. This is an MVP starting point, **not** a claim it scales indefinitely with arbitrary per-subscription consumers.

- Use stable internal subject IDs rather than public strings.
- Max event size 64 KiB; max age 7 days; impose hard per-instance storage cap and configurable discard policy.
- Use file storage with an explicit persistent directory; configure disk capacity, fsync/durability settings, and NATS server version.
- Embedded single-process NATS is a convenient deployment mode, not a clustered high-availability system.
- Support a remote NATS URL via config for operators wanting independent broker lifecycle/replication.
- An abstract broker interface should allow future benchmarking of sharded streams, group consumers, or alternate storage without rewriting MCP/API/identity code.
- Never expose a raw publish/subscribe NATS account to clients: public access goes through the hub ACL and quota checks.

## 10. HTTP endpoints and CLI

**Public:** `/mcp` (remote MCP), `/healthz`, `/readyz`, and standard OAuth discovery/authorization endpoints as applicable. A webhook sender calls third-party receivers; the hub does not require a public inbound webhook route for subscription delivery.

**Administrative (authenticated/local only):** inspect namespace, channel, subscription status, retention, failed deliveries, metrics. Keep this separate from the three MCP domain tools.

CLI sketch:

```shell
agenthub init --data-dir ./data
agenthub serve --config ./agenthub.yaml
agenthub admin namespace create opennews --account <id>
agenthub admin subscriptions list
agenthub admin subscriptions retry <subscription-id>
agenthub version
```

Example config:

```yaml
listen: "127.0.0.1:8080"
public_url: "http://127.0.0.1:8080"
data_dir: "./data"
auth:
  mode: local
nats:
  mode: embedded # or external
  store_dir: "./data/jetstream"
  # url: "nats://127.0.0.1:4222"
retention:
  max_age: 168h
  max_payload_bytes: 65536
  max_storage_bytes: 1073741824
webhooks:
  timeout: 10s
  max_attempts: 12
  max_in_flight_per_subscription: 1
```

Do not ship production instructions with loopback HTTP example mistaken for production TLS/OAuth settings.

## 11. Developer experience and documentation

Ship a 5-minute demo that works entirely on localhost:

1. Start the hub in embedded mode with persistent JetStream.
2. Create two local test accounts and namespaces (`alice`, `bob`).
3. Start a tiny Go or Python receiver with a verified local webhook.
4. Bob subscribes to `@alice/news` through MCP; Alice publishes through MCP.
5. Receiver prints event and acknowledges it.
6. Stop receiver; publish two more events; restart receiver; observe replay without duplicates under normal conditions.
7. Restart the whole hub; verify metadata and undelivered events survive.
8. Unsubscribe and confirm that subsequent publishes do not deliver to Bob.

Provide Go import example and Docker Compose example. README should prominently explain: webhook target is an **agent host/application**, not a magical notification mechanism inside every LLM; MCP-host support varies.

## 12. Security and operational requirements

- Namespace ownership checked for every publish; subscription and credential ownership checked for every modification.
- Restrict hosted-instance webhook egress (SSRF), bind internal NATS only to internal interfaces, require TLS at public ingress.
- Request-size and payload limits; per-account publish rates; maximum subscriptions/account; bounded concurrent callbacks.
- Prevent unbounded stream and durable consumer proliferation. Defaults are initial guardrails and must be benchmarked.
- Audit account/namespace/endpoint mutations without logging opaque payload contents.
- Structured logs: request ID, subscription ID, event ID, retries, errors, latency, but **never** bearer tokens, webhook secrets, or payload bodies by default.
- Metrics: accepted publishes/sec, publish failures, stream bytes/age, active subscriptions, delivery successes/failures, lag, oldest pending event, retry queue, redelivery rate, worker saturation.
- Health checks should distinguish the HTTP listener being alive from broker/metadata readiness.
- Graceful shutdown: stop accepting publishes, drain/bound callbacks, and leave unacked messages for replay.
- Explicit documented limits and abuse controls for public multi-tenant hosting.

## 13. Acceptance tests

### Functional

- Namespace collisions are rejected under concurrent claims; canonicalization is deterministic.
- Alice can publish to `@alice/news`, not `@bob/news`.
- Bob subscribes to Alice's channel and receives an event without polling.
- Alice and Carol subscribing independently both receive every event (no unintended load balancing).
- Opaque JSON and binary payloads round-trip byte-for-byte (under applicable transport representation).
- `publish` returns only after JetStream storage acknowledgment.
- Duplicate `subscribe` calls do not create duplicate deliveries.
- `unsubscribe` stops future deliveries and eventually removes durable broker state.

### Reliability

- Receiver downtime causes backlog that is delivered on recovery within retention.
- Hub restart preserves owner records, subscriptions, and unacked events.
- Webhook timeout or 5xx produces retries and possible duplicates, never a false guaranteed exactly-once claim.
- Retention expiration produces a visible gap/failure diagnostic.
- Slow receiver does not block unrelated subscribers.
- Broker outage causes publish failure (not false success).

### Security

- Forged/expired OAuth tokens rejected; user cannot impersonate another namespace.
- Invalid webhook signatures rejected by reference receiver.
- Hosted service rejects webhook URLs for localhost/private IPs and DNS rebinding.
- Payload/connection/subscription limits are enforced.
- Malformed channel strings cannot inject NATS wildcards.

### Embedding

- A Go example imports the core library, supplies config, starts the service, and shuts it down cleanly.
- Embedded mode uses durable disk storage, survives process restart, and binds broker privately.
- External NATS mode passes the same functional test suite.

## 14. Implementation phases

### Phase A — Working vertical slice

- Go module, config, embedded and external NATS modes, SQLite migrations.
- Namespace/account model with local development tokens.
- Internal `Publish`, `Subscribe`, `Unsubscribe` use cases.
- JetStream persistent stream, filtered durable subscriptions, retry workers.
- HTTPS webhook adapter and reference receiver.
- End-to-end test: one publish, two webhook subscribers, outage/replay.

**Stop point:** Complete a reliable pub/sub service independent of MCP.

### Phase B — Agent interface and hosted auth

- MCP server exposing exactly three domain tools.
- Standards-conformant remote MCP authorization flow and namespace claim UI.
- OAuth scopes, account provisioning, documentation, misuse hardening.
- Compatibility testing with at least two MCP clients, recording which clients support tool invocation, streaming subscriptions, and proactive wake-up.

**Stop point:** Agents can authorize and publish/subscribe, with real push to a webhook-capable host.

### Phase C — Distributable v0.1

- Importable public Go API, single-binary embedded mode, Docker image, sample config.
- Health, metrics, logs, limits, restart recovery, ops documentation.
- Load tests to establish honest supported ceilings for publishing, concurrent subscriptions, webhook fan-out, latency, and storage.
- Publish a v0.1 release under an open-source license.

### Later, explicitly deferred

- Federated hubs and remote channel routing.
- WebSocket/SSE delivery enhancements and standardized agent-host push adapters.
- Generalized MCP resource-change subscriptions if broadly interoperable.
- Channel discovery, private channels, richer access policies.
- Postgres/control-plane clustering, per-tenant stream partitioning.
- Optional per-channel schema documents and conventions (not enforcement).

## 15. Architectural decisions for the coding agent

1. **Do not build Rails** or introduce another web framework that requires a separate runtime.
2. **Do not build a new broker**; use NATS JetStream rather than replicating its persistence/ack machinery.
3. **Do not interpret payloads**; preserve and deliver bytes plus transport metadata.
4. **Do not reduce `subscribe` to polling**. A subscription must create an actual pushed destination; a client without a compatible receiver gets a clear capability error, not a silently ineffective subscription.
5. **Do not promise universal MCP event wake-up**. Capability negotiation and actual host compatibility are required.
6. **Do not create one NATS stream for every channel**. Start with a bounded shared stream and filtered consumers.
7. **Do not use NATS WorkQueue retention** for broadcast subscriptions.
8. **Do not equate webhook 2xx with AI completion**. The transport is at least once; business actions are outside the hub.
9. **Do not silently lose events** on retention expiry or retry exhaustion; publish diagnostics and expose clear failure state.
10. **Do not conflate human login with OAuth for remote MCP**; implement appropriate resource-server/authorization flow.
11. **Keep the deployable server and embedded library on the same core code path**.
12. **Benchmark before marketing huge scale**: per-subscriber durable consumers and webhooks have real storage/CPU/network costs.

## 16. External documentation to consult before coding

- NATS JetStream fundamentals: https://docs.nats.io/concepts/jetstream
- NATS JetStream deep dive: https://docs.nats.io/learn/jetstream/
- NATS Go JetStream API: https://pkg.go.dev/github.com/nats-io/nats.go/jetstream
- NATS embedded server Go package: https://pkg.go.dev/github.com/nats-io/nats-server/v2/server
- MCP specification (pin tested version): https://modelcontextprotocol.io/specification/2026-07-28

**First coding agent assignment:** Implement Phase A end-to-end, with robust tests and a clean embeddable library boundary. Do not spend Phase A building a polished dashboard, federation, social features, an LLM service, or speculative protocols.
