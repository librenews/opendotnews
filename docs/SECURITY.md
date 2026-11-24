# Open.News — Security Model & Hardening

Open.News is designed to handle untrusted external XML/HTML feeds, third-party push callbacks, public Markdown publishing, and remote AI agents safely on a single self-hosted VPS.

---

## 1. SSRF Protection (`Security::SafeHttpFetch`)
Every outbound HTTP request — feed discovery, polling, WebSub subscribe/verify/delivery, and rssCloud registration/challenge/ping — passes through [safe_http_fetch.rb](../app/services/security/safe_http_fetch.rb):
- Allows only `http` and `https` schemes with no embedded userinfo.
- Resolves DNS manually before connecting and rejects loopback (`127.0.0.0/8`, `::1`), RFC1918 private networks, CGNAT, link-local / cloud metadata IMDS (`169.254.0.0/16`, `fd00:ec2::254`), multicast, documentation, and IPv4-mapped IPv6 equivalents.
- Pins the validated IP onto `Net::HTTP#ipaddr=` to prevent DNS rebinding TOCTOU races.
- Revalidates every redirect hop up to `FEED_MAX_REDIRECTS` (default `5`), caps raw response bytes (`FEED_MAX_BYTES`), and streams gzip/deflate decompression with a hard `FEED_MAX_DECOMPRESSED_BYTES` cap against decompression bombs.

## 2. XML, HTML & Markdown Sanitization
- All RSS, Atom, OPML, and XML-RPC parsing uses strict Nokogiri (`NONET`, no DTD load, no entity expansion) and explicitly rejects `<!DOCTYPE` / `<!ENTITY` declarations (XXE prevention).
- External feed HTML is sanitized with `Loofah` (`:prune` scrubber) stripping scripts, event handlers, and `javascript:`/`vbscript:`/`data:` URL schemes.
- Hosted Markdown renders via `Commonmarker` with `unsafe: false` (raw HTML disabled) followed by `Loofah` sanitization.
- Strict Content-Security-Policy (`script-src 'none'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'`) plus `X-Content-Type-Options: nosniff` and `Referrer-Policy: strict-origin-when-cross-origin` are applied globally in [content_security_policy.rb](../config/initializers/content_security_policy.rb).

## 3. Authentication, Authorization & Secrets
- **OAuth 2.1:** PKCE `S256` required; access and refresh tokens are hashed with SHA-256 at rest via Doorkeeper (`hash_token_secrets`); strict `Origin` validation on `/mcp`.
- **Encryption at Rest:** Upstream and downstream WebSub shared secrets and callback tokens are encrypted at rest via Active Record Encryption (`ACTIVE_RECORD_ENCRYPTION_*` env vars).
- **Private-by-Default Isolation:** Every feed item, search query, `UserItem` state, inbox cursor, and document draft is strictly scoped to the authenticated owner. `publish_document` defaults to `visibility: "draft"`.
- **Log Redaction:** Passwords, tokens, secrets, authorization headers, raw Markdown, and OPML XML are filtered via [filter_parameter_logging.rb](../config/initializers/filter_parameter_logging.rb).

## 4. Quotas, Rate Limiting & Moderation
- **Rack::Attack** throttles `/login`, `/oauth/register`, `/mcp`, `/callbacks/*`, `/websub/hub`, and `/rsscloud/*`.
- **Env-Driven Quotas (`Security::Quotas`):** `MAX_SUBSCRIPTIONS_PER_USER`, `MAX_DOCUMENTS_PER_USER`, `MAX_DOCUMENT_STORAGE_BYTES_PER_USER`, `MAX_PUBLISHES_PER_HOUR`, `MAX_DOWNSTREAM_SUBSCRIBERS_PER_PUBLICATION`, and `MAX_DOWNSTREAM_FANOUT_PER_EVENT`.
- **Moderation & Erasure:** Operators (`/admin/metrics`) can disable abusive accounts (immediately revoking sessions/OAuth tokens and suspending downstream push) and take down public documents (returning `451 Unavailable For Legal Reasons` and removing them from RSS/Atom feeds). Users can self-erase their account and private reading data at `/settings/account` while preserving deleted namespace/URL tombstones.
- **Abuse Contact:** Published at `/.well-known/security.txt` (configured via `ABUSE_CONTACT_EMAIL`).
