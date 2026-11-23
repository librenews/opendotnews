# opendotnews

`opendotnews` is a small, open-source, embeddable, self-hostable publish/subscribe event hub for agents, written in Go and backed by **NATS JetStream** and **SQLite** (WAL).

**Dumb by design:** `opendotnews` does not inspect payload schemas, classify content, call an LLM, or run subscribers' agents. Publishers send opaque bounded bytes to a namespaced channel (`@namespace/channel/path`), and subscribers receive push deliveries via authenticated HTTPS webhooks with bounded JetStream retention and replay.

> **Important note on receivers:** A webhook target is an **agent host or application**, not a magical wake-up mechanism inside an arbitrary hosted LLM. Receiving HTTP `2xx` means the receiver accepted transport delivery—at-least-once delivery semantics apply, so receivers should deduplicate by `(subscription_id, event_id)`.

## Current Status — Phase A Complete

Phase A delivers the complete, standalone, embeddable pub/sub vertical slice:

- **Single-binary & embeddable Go package** (`pkg/opendotnews`) with zero CGO dependencies (`modernc.org/sqlite`)
- **Embedded NATS JetStream** (persistent file storage, private loopback bind) + **External NATS** mode
- **Namespace & channel ownership ACLs** (`@namespace/channel/path`), opaque internal NATS subjects (`ev.<ns_id>.<ch_id>`), strict wildcard/traversal/remote-channel rejection
- **Authenticated HTTPS webhooks**: HMAC-SHA256 signing (`X-OpenDotNews-*` headers), key rotation, ownership challenge handshake before activation, connect-time SSRF & DNS-rebinding protection, disallowed redirects
- **Durable broadcast fan-out**: single shared `Limits` JetStream stream (`OPENDOTNEWS_EVENTS`), independent durable filtered pull consumers per subscription, bounded worker pools, exponential backoff + jitter, `4xx` / retry-exhaustion pausing with `delivery_failures` diagnostics, and retention-gap detection
- **Crash-consistent lifecycle reconciliation** on startup (`provisioning`, `active`, `deleting`)
- **CLI & HTTP API** (`init`, `serve`, `admin`, `/healthz`, `/readyz`, `/v1/*`, `/admin/*`)

*(Phase B will add the 3 remote MCP tools—`publish`, `subscribe`, `unsubscribe`—plus standards-conformant MCP OAuth 2.1 and namespace claiming.)*

## Quick Start (Localhost)

### 1. Build

```bash
go build -o ./bin/opendotnews ./cmd/opendotnews
```

### 2. Initialize & Create Two Local Accounts

```bash
./bin/opendotnews init --data-dir ./data --config ./opendotnews.yaml
# For localhost HTTP webhook testing, enable in opendotnews.yaml:
#   webhooks.allow_insecure_http: true
#   webhooks.allow_private_destinations: true

./bin/opendotnews admin account create alice --config ./opendotnews.yaml
./bin/opendotnews admin account create bob   --config ./opendotnews.yaml

# Replace <alice_id> and <bob_id> with the printed account IDs:
./bin/opendotnews admin namespace create alice --account <alice_id> --config ./opendotnews.yaml
./bin/opendotnews admin token create --account <alice_id> --config ./opendotnews.yaml
./bin/opendotnews admin token create --account <bob_id>   --config ./opendotnews.yaml
```

### 3. Run the Hub & Reference Webhook Receiver

In terminal 1:
```bash
./bin/opendotnews serve --config ./opendotnews.yaml
```

In terminal 2:
```bash
go run ./examples/webhook-receiver --listen 127.0.0.1:9090
```

### 4. Subscribe & Publish

```bash
# Bob subscribes to @alice/news (returns signing_secret for HMAC verification)
curl -s -X POST http://127.0.0.1:8080/v1/subscriptions \
  -H "Authorization: Bearer <bob_token>" \
  -H "Content-Type: application/json" \
  -d '{"channel":"@alice/news","delivery":{"mode":"webhook","url":"http://127.0.0.1:9090/webhook"}}'

# Alice publishes an opaque JSON payload
curl -s -X POST http://127.0.0.1:8080/v1/publish \
  -H "Authorization: Bearer <alice_token>" \
  -H "Content-Type: application/json" \
  -d '{"channel":"@alice/news","content_type":"application/json","payload":{"url":"https://example.org/agenda/42"}}'
```

## Embedding in Go

See [examples/embedded/main.go](examples/embedded/main.go) for a complete runnable program importing `github.com/librenews/opendotnews/pkg/opendotnews`.

## Testing

```bash
go test -v ./...
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
