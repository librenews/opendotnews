# Open.News — Protocol Interoperability & Troubleshooting

Open.News implements all four bidirectional syndication roles over standard HTTP, RSS 2.0, Atom 1.0, WebSub, and rssCloud.

---

## 1. Hosted Public URLs & Content Negotiation

| URL | Behavior |
|---|---|
| `/:namespace` | Public HTML publication index advertising RSS & Atom `<link rel="alternate">` |
| `/:namespace/feed.xml` | RSS 2.0 feed with stable `urn:uuid:...` GUIDs, `<atom:link rel="hub">`, and `<cloud>` element |
| `/:namespace/feed.atom` | Atom 1.0 feed with stable `urn:uuid:...` IDs and `<link rel="hub">` |
| `/:namespace/*path` | Serves safe HTML by default; serves exact UTF-8 Markdown when `Accept: text/markdown` is preferred (`Vary: Accept`, representation-specific `ETag`, `304 Not Modified`, optional read-only `?revision=N`) |
| `/:namespace/*path.md` | Explicit Markdown alias sending `Link: <canonical>; rel="canonical"` |

- Draft documents return `404 Not Found` publicly.
- Deleted previously-public documents return `410 Gone` permanently (URLs are never recycled).
- Moderation-removed documents return `451 Unavailable For Legal Reasons`.

---

## 2. Upstream Push (Reader Ingestion)

1. **WebSub Subscriber (`/callbacks/websub/:token`)**
   - Automatically discovers `rel="hub"` and `rel="self"` from HTTP `Link` headers or feed XML.
   - Maintains **one shared `UpstreamPushSubscription` per canonical feed** regardless of subscriber count.
   - Verifies `X-Hub-Signature` (`sha256` / `sha1`) in constant time, stages payload durably in `staged_push_payloads`, returns `202 Accepted`, and ingests pushed RSS/Atom XML directly without a follow-up HTTP fetch.
   - Falls back to conditional polling (`ETag`/`Last-Modified`) if the upstream hub goes offline.

2. **rssCloud Consumer (`/callbacks/rsscloud/:token`)**
   - Discovers RSS `<cloud>` and `<source:cloud>` elements; supports both REST (`http-post`) and XML-RPC (`pleaseNotify`).
   - Renews leases before the 25-hour expiration via `Push::RenewUpstreamJob` (every 15 minutes).
   - Coalesces burst pings per feed into a single SSRF-safe `Feeds::FetchJob`.

---

## 3. Downstream Push (Hosted Publishing)

1. **WebSub Hub (`POST /websub/hub`)**
   - Accepts `hub.mode=subscribe|unsubscribe` **only** for public hosted `/:namespace/feed.xml` and `/:namespace/feed.atom` topics on `APP_BASE_URL` (never acts as an open third-party relay).
   - Verifies subscriber intent via GET challenge before activating, clamps finite leases (`60s`–`10d`), enforces `hub.secret < 200 bytes`, and delivers full RSS/Atom XML (`fat push`) with `X-Hub-Signature: sha256=<hex>` and `Link` headers.

2. **rssCloud Cloud Server (`POST /rsscloud/pleaseNotify`, `POST /rsscloud/RPC2`, `POST /rsscloud/ping`)**
   - Supports REST (`http-post`) and XML-RPC registration with GET challenge verification and 25-hour finite leases.
   - Delivers lightweight feed-URL pings (`url=<feed_url>` or XML-RPC `notifyProcedure(feed_url)`) on publication changes.
   - `POST /rsscloud/ping` accepts only hosted feeds on this instance (`403` for external URLs).

3. **Retry & Delivery Policy**
   - `2xx`: marked `delivered`.
   - `410 Gone`: subscription automatically marked `unsubscribed`.
   - `408` / `429` / `5xx` / transient network error: exponential backoff (respecting `Retry-After`) up to 6 attempts via `Delivery::RetryDueJob`.
   - SSRF block or repeated permanent `4xx`: subscription marked `suspended`.

---

## 4. Troubleshooting Checklist
- **Callbacks not arriving:** Ensure `APP_BASE_URL` is set to your public HTTPS origin (external hubs cannot reach `localhost`).
- **Feed not updating:** Inspect `/feeds/:id` for `last_http_status`, `last_error`, `fetch_failure_count`, and upstream push lease status.
- **Downstream subscriber not receiving updates:** Inspect `/publishing/deliveries` for subscriber status (`active` vs `expired`/`unsubscribed`/`suspended`) and `DeliveryAttempt` HTTP codes.
- **Operator health overview:** Check `/health/ready` and `/admin/metrics` (or `GET /admin/metrics.json` with `Authorization: Bearer $OPERATOR_METRICS_TOKEN`).
