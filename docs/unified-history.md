# Unified iPhone history contract

Status: normative contract for the Unified History PWA slice. The Mac is the authoritative
history store. Cloudflare transports history and never persists it. The PWA keeps an
IndexedDB convenience cache. Everything below is snake_case JSON unless stated otherwise.

## 1. Mac history additions

`dictation_history` gains these columns (migration `history_unified_v3`, additive, idempotent):

| Column | Type | Default | Notes |
|---|---|---|---|
| `source_kind` | text not null | `desktop` | `desktop`, `iphone_shortcut`, `iphone_pwa` |
| `remote_route` | text | null | `mac_local`, `cloud_fallback` |
| `cleanup_backend` | text | null | `apple_foundation`, `deterministic`, `none` |
| `user_edited_text` | text | null | user edit; raw and polished text remain immutable |
| `is_pinned` | boolean not null | false | pinned entries are exempt from retention pruning |
| `entry_revision` | integer not null | 1 | bumped on every mutation of that row |
| `updated_at` | datetime not null | = `timestamp` for existing rows | wall-clock of last mutation |

Display text resolves as `user_edited_text → polished_text → raw_text`.

A single-row `history_sync_state(global_revision integer)` table holds a monotonic counter
that is bumped by every insert, update, delete, prune, and bulk deletion. A
`history_sync_operations(op_id text primary key, entry_id text, status text, applied_at datetime)`
table records applied client operations so replays are idempotent.

The FTS index (`history_fts_v3`) covers `raw_text`, `polished_text`, `user_edited_text`,
`destination_display_name`, `destination_bundle_identifier`.

Retention: unpinned entries are pruned after `history_success_retention_days` (default 90).
Pinned entries are never pruned. Secure-field sessions still create no row.

Remote entries (Mac-local or imported) use the existing `delivered` delivery status (the text was
returned to the device) and are identified by a non-null `remote_route`.

## 2. Transcription contract additions

Request header (gateway and Mac origin). Optional on `/v1/transcriptions` with default
`shortcut`; the PWA MUST send `pwa` on every request so its Mac-saved entries carry
`source_kind = iphone_pwa`. Required (exactly `pwa`) on every `/v1/history/*` request.

```
X-Dictation-Client: shortcut | pwa
```

Response gains `history_state`:

```json
{
  "request_id": "uuid",
  "text": "Transcribed text",
  "route": "mac_local",
  "cleanup": "apple_foundation",
  "latency_ms": 842,
  "fallback_reason": null,
  "history_state": "saved_on_mac"
}
```

| `history_state` | Meaning |
|---|---|
| `saved_on_mac` | The Mac saved raw + cleaned text under `request_id` before returning. |
| `pending_device_sync` | Nothing is saved on the Mac; the device must keep the text and import it later. Always the value for `cloud_fallback`. Also returned when unified history is on but the save failed. |
| `disabled` | Unified history is off on the Mac; nothing was saved. The device still keeps the text and queues an import so enabling unified history later picks it up. |

The gateway passes the Mac value through for `mac_local` (treating a missing field as
`disabled`) and always sets `pending_device_sync` for `cloud_fallback`.

Mac-local iPhone entries use `request_id` as the history entry id, `source_kind` from
`X-Dictation-Client`, `remote_route = mac_local`, `cleanup_backend` from the response, no
destination, `delivery_status = delivered`. A duplicate `request_id` is idempotent.

## 3. History API

Same paths on the Mac loopback listener (`127.0.0.1:43129`) and on the gateway
(`https://dictate.natemunk.com`). The gateway only proxies these to the Mac origin with the
origin service token. It never invokes Workers AI, never caches, never stores bodies.

### Entry DTO

```json
{
  "id": "6f1d2c3e-…",
  "created_at": "2026-09-06T17:20:00.000Z",
  "updated_at": "2026-09-06T17:21:10.500Z",
  "source_kind": "desktop",
  "mode": "clean",
  "raw_text": "…",
  "polished_text": "…",
  "user_edited_text": null,
  "display_text": "…",
  "destination_display_name": "Notes",
  "remote_route": null,
  "cleanup_backend": null,
  "is_pinned": false,
  "entry_revision": 1
}
```

Dates are ISO 8601 UTC with fractional seconds. UUIDs are lowercase. The DTO never carries
bundle identifiers, error text, latencies, credentials, or diagnostics.

### `GET /v1/history/manifest`

```json
{
  "revision": 42,
  "entry_count": 120,
  "pinned_count": 3,
  "retention": { "unpinned_days": 90, "pinned": "until_unpinned_or_deleted" },
  "max_operations_per_request": 100,
  "max_text_characters": 100000
}
```

### `GET /v1/history?revision=42&cursor=<opaque>&limit=100`

`revision` is required and must equal the current global revision, otherwise
`409 {"error":"history_changed","revision":<current>}`. `limit` is 1–100 (default 100).
Ordering is newest-inserted first; `cursor` is opaque (the Mac uses the last row id).

```json
{ "revision": 42, "entries": [ … ], "next_cursor": "118" }
```

`next_cursor` is `null` on the last page. Clients sort by `created_at` locally.

### `POST /v1/history/operations`

Body (≤ 100 operations, ≤ 2 MiB, each `text` ≤ 100 000 characters):

```json
{ "operations": [
  { "op_id": "uuid", "type": "import", "entry_id": "uuid", "created_at": "ISO8601",
    "source_kind": "iphone_shortcut", "mode": "clean", "text": "…",
    "route": "cloud_fallback", "cleanup": "none" },
  { "op_id": "uuid", "type": "edit",   "entry_id": "uuid", "base_revision": 3, "text": "…" },
  { "op_id": "uuid", "type": "pin",    "entry_id": "uuid", "base_revision": 3 },
  { "op_id": "uuid", "type": "unpin",  "entry_id": "uuid", "base_revision": 3 },
  { "op_id": "uuid", "type": "delete", "entry_id": "uuid", "base_revision": 3 }
] }
```

Response:

```json
{ "revision": 43, "results": [
  { "op_id": "uuid", "status": "applied", "entry": { … } },
  { "op_id": "uuid", "status": "conflict", "entry": { …current server state… } },
  { "op_id": "uuid", "status": "already_applied", "entry": { … } | null },
  { "op_id": "uuid", "status": "missing", "entry": null },
  { "op_id": "uuid", "status": "invalid", "entry": null }
] }
```

Semantics:

- The whole batch runs in one Mac database transaction; each operation is evaluated
  independently and never rolls back its neighbours.
- `op_id` replay of a previously applied operation returns `already_applied`.
- `import`: creates the entry (`raw_text = text`, `polished_text = null`,
  `source_kind` ∈ {`iphone_shortcut`,`iphone_pwa`}, `route` ∈ {`mac_local`,`cloud_fallback`},
  `delivery_status = delivered`). Existing `entry_id` → `already_applied`.
- `edit`: sets `user_edited_text` (empty or whitespace-only `text` clears it). Requires
  `base_revision == entry_revision`, else `conflict` with the current entry.
- `pin` / `unpin`: same revision rule. Setting the already-current state is `applied`.
- `delete`: same revision rule; a missing entry is `already_applied`.
- Any op whose `entry_id` does not exist (other than import/delete) → `missing`.
- Malformed op → `invalid`; malformed body → `400 {"error":"invalid_request"}`.
- Global revision is bumped once when at least one op was applied.

### Errors

Mac origin: `403 {"error":"history_disabled"}` when unified history is off,
`400 {"error":"invalid_request"}`, `409 {"error":"history_changed","revision":N}`,
`413 {"error":"payload_too_large"}`. Every response is `Cache-Control: no-store`.

Gateway envelope (the PWA only ever talks to the gateway):

| Gateway status | `error.code` | When |
|---|---|---|
| 503 | `MAC_UNAVAILABLE` | tunnel/app/health unreachable or timed out |
| 403 | `HISTORY_DISABLED` | Mac returned `history_disabled` |
| 409 | `HISTORY_CHANGED` (+ `revision`) | Mac returned `history_changed` |
| 400/413 | `INVALID_REQUEST` / `PAYLOAD_TOO_LARGE` | validation failure at gateway or Mac |
| 503 | `ORIGIN_AUTH_FAILED` | origin service token rejected |

Successful bodies are forwarded verbatim after bounded-size JSON validation (≤ 4 MiB).
Timeouts: 10 s for manifest and snapshot pages, 20 s for operations. History requests
require `X-Dictation-Client: pwa`; other values → `400 INVALID_REQUEST`.

Gateway health moves to `GET /v1/healthz` (Access-protected). The unprotected `/healthz`
path no longer exists on the gateway. The Mac origin keeps `/healthz`.

## 4. Synchronization algorithm (PWA)

1. Queue every local mutation as an operation with a fresh `op_id`; persist the queue in
   IndexedDB before any network call.
2. When online, POST the queue in batches of ≤ 100 first. Apply results: `applied` and
   `already_applied` remove the op; `missing` removes the op and the local entry;
   `conflict` keeps the op flagged for visible resolution (Keep mine → resend with the
   server's `entry_revision`; Take server → drop the op and adopt the server entry).
3. Fetch the manifest. If `revision` equals the cached synchronized revision, stop.
4. Otherwise page through `/v1/history?revision=R` and write all pages into a staging
   store; on the last page atomically replace the synchronized cache with the staging
   set, then record `R` as the synchronized revision.
5. `HISTORY_CHANGED` during paging restarts from step 3 (max 5 attempts per sync).
6. `MAC_UNAVAILABLE` leaves the cache and queue untouched and shows Offline. Pending
   local entries (not yet imported) are shown alongside the last synchronized snapshot.
7. `HISTORY_DISABLED` shows a persistent notice. Recording still works, and imports stay
   queued so enabling unified history on the Mac later imports them.

## 5. PWA

Served from the gateway Worker at `/app/` via Worker static assets. Plain HTML/CSS/JS, no
framework, no third-party runtime scripts, no inline scripts or inline event handlers, no
`innerHTML`/`outerHTML`/`insertAdjacentHTML`/`document.write`/`eval`/`new Function` at all (the
privacy audit rejects them whether static or dynamic), no inline `style=""` attributes, strict
CSP, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, no caching of `/v1/*`, shell
assets cached only by the service worker under a versioned cache name.

Routes: `/app/` (main), `/app/import` (fragment import; serves the same shell).

Credentials: a dedicated PWA Access service token pasted once into Settings, stored only in
IndexedDB, redacted in the UI, removable with Clear Credentials. Sent as
`CF-Access-Client-Id` / `CF-Access-Client-Secret` on every `/v1/*` request.

Recording: `MediaRecorder` with `audio/mp4` preferred (`audio/webm` fallback is sent with its
real MIME type and is expected to be rejected by the gateway as unsupported; the UI says so),
12 MiB / 10 min limits, tracks stopped on stop/error, audio never written to IndexedDB.

Every successful transcription becomes a local entry immediately. If `history_state` is
`pending_device_sync` or `disabled`, an `import` op is queued.

### UX principles (non-negotiable)

The PWA must be the simplest dictation app imaginable. Nate's direction: "most simple as
possible and user friendly app to ever live."

- One screen. A single enormous Record button dominates the top; tapping it again stops.
  No mode pickers, toggles, or status chips compete with it.
- The transcript appears directly under the button the moment it is ready, with one big
  **Copy** button. Copy is the only thing most sessions need.
- History is a plain scrolling list beneath, newest first, one tap opens an entry, one tap
  copies. Search is a single field that appears only when the list has more than a few items.
- Secondary actions (Edit, Pin, Delete) live inside an entry, not on the list.
- Everything else (Clean/Literal, cloud fallback, credentials, export, delete cache, install
  help, connection test, privacy text) lives behind a single gear icon.
- Status is a single short line under the button ("Mac", "Cloud", "Offline", "Syncing…"), no
  badges soup. Errors are one plain sentence with one obvious next action.
- Big type, big touch targets (≥ 48 px), generous spacing, system font, respects safe areas
  and dark mode. No decorative chrome, no icons without labels, no jargon (never show
  "revision", "op", "IndexedDB", "DTO", "conflict" — say "This was changed on your Mac too.
  Keep mine / Use Mac's").
- First launch with no credentials shows one friendly setup card with two fields and a Save
  button, nothing else.

## 6. Shortcut bridge

After a successful transcription the Shortcut reads `history_state`:

- `saved_on_mac` → nothing more.
- otherwise → copy the text (already done), then Open URL:

```
https://dictate.natemunk.com/app/import#v=1&id=<request uuid>&ts=<ISO8601 url-encoded>&mode=<clean|literal>&route=<route>&client=shortcut&text=<url-encoded text>
```

If the text is longer than 16 000 characters, open instead:

```
https://dictate.natemunk.com/app/import#v=1&id=…&ts=…&mode=…&route=…&client=shortcut&clipboard=1
```

and the PWA shows one **Import Copied Transcript** button that reads the clipboard on tap.
The PWA validates every field, stores the entry, queues an `import`, and replaces the URL
with `/app/` via `history.replaceState` before rendering. Failed requests never open the PWA.

### PWA live-audio transport

Dictation Inbox prefers live audio without making it a correctness dependency. It starts the
ordinary in-memory `MediaRecorder` file and a 16 kHz PCM tap from the same microphone stream.
The PWA uses its Access-protected `/v1` credentials to mint a 30-second signed stream ticket,
then presents that ticket as a WebSocket subprotocol to public `/stream`. The Worker validates
the signature, expiry, same-origin request, UUID, mode, and fallback consent; strips the ticket;
adds its separate origin Access credentials; and transparently proxies frames. The ticket and
PCM are memory-only and never enter URLs, IndexedDB, logs, or Cloudflare storage.

The Mac feeds PCM to optional EOU preview and a temporary 16 kHz WAV simultaneously. On Stop,
the selected batch engine and normal cleanup/history pipeline produce the authoritative response.
A failed ticket, unsupported browser, dropped socket, preemption, or failed stream finalization
causes the PWA to submit its completed recording through `/v1/transcriptions` with the same
request UUID. Only that file path may invoke cloud fallback. Shortcuts always use the file path.

## 7. Cloudflare Access and tokens

Three distinct service tokens:

1. Shortcut → gateway (`dictate.natemunk.com/v1`, Service Auth policy A)
2. PWA → gateway (`dictate.natemunk.com/v1`, Service Auth policy B)
3. Worker → Mac origin (`dictate-origin.natemunk.com`, Service Auth policy C, Worker secrets)

The gateway Access application is path-scoped to `dictate.natemunk.com/v1`. A separate PWA Shell
Bypass application has the two explicit destinations `dictate.natemunk.com/app` and
`dictate.natemunk.com/stream`, which keeps broader wildcard Access applications from intercepting
those browser routes. `/stream` must be publicly reachable because browser WebSockets cannot attach
the Access service-token headers; it accepts only the short-lived HMAC ticket minted under protected `/v1`.
Setup verifies, in order: (a) anonymous `/app/` returns 200 with a
`Content-Security-Policy` header; (b) anonymous `/v1/healthz` is not 200; (c) anonymous
origin `/healthz` is not 200; (d) the Shortcut token reaches `/v1/healthz`; (e) the PWA token
reaches `/v1/healthz`; (f) the origin token does NOT reach `/v1/healthz`; (g) the Shortcut
token does NOT reach origin `/healthz`; (h) the PWA token does NOT reach origin `/healthz`;
(i) the origin token reaches origin `/healthz`; (j) `/stream` reaches the Worker's own guard and
refuses a request without a valid ticket. The signing secret exists only as a Worker secret and rotates independently of all three
Access tokens.

References: [self-hosted applications](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/),
[application paths](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/app-paths/),
[service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/),
[Worker static assets](https://developers.cloudflare.com/workers/static-assets/).

## 8. Mac settings

Settings → iPhone gains **Unified iPhone History** (off by default). When off: no remote
transcript is persisted, history routes return `history_disabled`, existing local history is
untouched. Enabling shows a disclosure that desktop history transits Cloudflare during PWA
synchronization.
