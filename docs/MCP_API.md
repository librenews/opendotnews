# Open.News — MCP & OAuth 2.1 API Reference

Open.News exposes a standards-compliant **Streamable HTTP MCP** server at `POST /mcp` (`GET /mcp` returns `405 Method Not Allowed`) authenticated with **OAuth 2.1 Authorization Code + PKCE (S256)**.

---

## 1. OAuth 2.1 Discovery & Dynamic Client Registration

| Endpoint | Standard | Purpose |
|---|---|---|
| `GET /.well-known/oauth-protected-resource` | RFC 9728 | Advertises `resource`, `authorization_servers`, `scopes_supported` |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 | Advertises authorization, token, revocation, and registration endpoints |
| `POST /oauth/register` | RFC 7591 | Dynamic Client Registration (public PKCE clients, bounded redirect URIs) |
| `GET/POST /oauth/authorize` | OAuth 2.1 | User consent & authorization code issuance (PKCE `S256` required) |
| `POST /oauth/token` | OAuth 2.1 | Token exchange & refresh token rotation |
| `POST /oauth/revoke` | RFC 7009 | Token revocation |

### Scopes

| Scope | Grants |
|---|---|
| `feeds:read` | List subscriptions, list/read/search subscribed feed items, poll durable updates, export OPML |
| `feeds:write` | Subscribe/unsubscribe feeds, import OPML |
| `documents:read` | List and read caller-owned Markdown documents (including private drafts and historical revisions) |
| `documents:write` | Create, revise, publish/unpublish, and delete caller-owned Markdown documents |

---

## 2. MCP Tools Catalog (15 Tools)

All calls use JSON-RPC 2.0 `POST /mcp` with `Authorization: Bearer <access_token>` and `Content-Type: application/json`.

### Reader & Archive Tools
1. **`subscribe_feed`** (`feeds:write`) — Discover and subscribe to an RSS/Atom feed or website URL. Args: `{ url, folder? }`. Returns `{ status, feed_id, canonical_url, title, already_subscribed }` or `selection_required` with candidate feed URLs.
2. **`unsubscribe_feed`** (`feeds:write`) — Remove an active feed subscription. Args: `{ feed_id }`.
3. **`list_subscriptions`** (`feeds:read`) — List caller's active subscriptions (optional `folder` filter).
4. **`list_feed_items`** (`feeds:read`) — List items from caller's subscribed feeds. Args: `{ feed_id?, folder?, since?, limit?, cursor?, unread_only?, saved_only?, exclude_archived? }`.
5. **`get_feed_item`** (`feeds:read`) — Fetch a single subscribed item (including full sanitized text and metadata). Args: `{ item_id }`.
6. **`search_items`** (`feeds:read`) — PostgreSQL full-text search (`websearch_to_tsquery`) strictly scoped to caller's active subscriptions. Args: `{ query, feed_id?, folder?, since?, until?, limit?, unread_only?, saved_only?, exclude_archived? }`.
7. **`get_updates`** (`feeds:read`) — Durable monotonic cursor stream (`user_inbox_events`) for disconnected agents. Args: `{ cursor?, limit? }`. Returns `{ events, next_cursor, has_more, cursor_expired }`.
8. **`import_opml`** (`feeds:write`) — Bounded OPML 1.0/2.0 import. Args: `{ opml_xml }`.
9. **`get_opml_import_status`** (`feeds:read`) — Check progress/results of an OPML import. Args: `{ import_id }`.
10. **`export_opml`** (`feeds:read`) — Export active subscriptions as OPML 2.0 XML.

### Markdown Publishing Tools
11. **`publish_document`** (`documents:write`) — Create a revisioned UTF-8 Markdown document under `/:namespace/*path`. **Defaults to `visibility: "draft"`** so agents never accidentally expose private notes. Args: `{ path, markdown, title?, visibility?: "draft"|"public", idempotency_key? }`.
12. **`get_document`** (`documents:read`) — Read a caller-owned document (including drafts and optional historical `?revision`). Args: `{ path, revision? }`.
13. **`update_document`** (`documents:write`) — Update Markdown, title, or visibility; supports optimistic locking (`expected_revision`) and `idempotency_key`. Args: `{ path, markdown?, title?, visibility?, expected_revision?, idempotency_key? }`.
14. **`list_documents`** (`documents:read`) — List caller's live documents (optional `visibility`, `limit`).
15. **`delete_document`** (`documents:write`) — Soft-delete a document. Previously public URLs become permanent `410 Gone` tombstones and are never recycled. Args: `{ path, expected_revision? }`.

### Common Structured Tool Errors
- `forbidden` — Missing OAuth scope.
- `not_found` — Resource does not exist or is not owned/subscribed by the caller.
- `path_conflict` / `revision_conflict` / `idempotency_conflict` — Document write safety conflicts.
- `payload_too_large` / `quota_exceeded` — Per-request or per-account limits exceeded.
