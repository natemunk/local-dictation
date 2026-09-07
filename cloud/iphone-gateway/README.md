# Local Dictation iPhone Gateway

Dependency-light Cloudflare Worker for the iPhone Shortcut and PWA endpoints. It accepts a bounded audio file, or transparently proxies a ticketed PWA WebSocket while audio is being recorded. It checks whether the tunnel-backed Mac service is ready for file requests and uses Cloudflare Workers AI only when the Mac cannot serve a completed file. It also proxies the unified history API to the Mac origin and serves the PWA shell from `/app/`.

The normative cross-component contract is [`../../docs/unified-history.md`](../../docs/unified-history.md).

## API

### `POST /v1/transcriptions`

Send the audio bytes directly as the request body.

Required:

- `Content-Type`: one of the supported `audio/*` types in `src/gateway.ts` (iPhone M4A is accepted as `audio/mp4`, `audio/m4a`, or `audio/x-m4a`).
- Body: non-empty and at most 12 MiB.
- `X-Audio-Duration-Seconds`: positive finite number, at most 600.
- `X-Dictation-Mode`: `clean` or `literal`.
- `X-Allow-Cloud-Fallback`: `true` or `false`. When `true`, fallback is automatic but remains visible in the response.
- `X-Request-ID`: a UUID generated once by the Shortcut and returned unchanged in the response.

The HTTP request body must not use a `Content-Encoding`; the audio file itself may use any accepted media type above.

Optional:

- `X-Transcription-Language`: BCP 47-style language tag; defaults to `en`.
- `X-Dictation-Client`: `shortcut` or `pwa`; defaults to `shortcut`. Any other value returns `400 INVALID_DICTATION_CLIENT`. The value is forwarded to the Mac origin so it can record `source_kind`.

Success:

```json
{
  "request_id": "uuid",
  "text": "Transcribed text",
  "route": "mac_local",
  "cleanup": "deterministic",
  "latency_ms": 842,
  "fallback_reason": null,
  "history_state": "saved_on_mac"
}
```

`route` is `mac_local` when the Mac handled the request and `cloud_fallback` when Workers AI handled it. Cloud fallback uses `@cf/openai/whisper-large-v3-turbo`, sets `cleanup` to `none`, and identifies why the Mac was skipped in `fallback_reason`. If the request sets `X-Allow-Cloud-Fallback: false`, Mac failure returns a no-store `503` instead.

`history_state` is one of `saved_on_mac`, `pending_device_sync`, or `disabled`. For `mac_local` the gateway passes the Mac value through unchanged; a missing or null field is reported as `disabled`, and any other value makes the origin response invalid. For `cloud_fallback` the gateway always reports `pending_device_sync`, because nothing was written on the Mac. The client keeps the transcript and queues an `import` operation whenever the state is not `saved_on_mac`.

All success and error responses include `Cache-Control: no-store`, `Pragma: no-cache`, and `X-Request-ID`.

### Live PWA stream

`POST /v1/stream-tickets` is Access-protected and requires `X-Dictation-Client: pwa`, a UUID `X-Request-ID`, `X-Dictation-Mode`, and `X-Allow-Cloud-Fallback`. It returns a 30-second HMAC-signed ticket, the `local-dictation.v1` subprotocol, and `/stream`. The response is `no-store`; the ticket is never logged or persisted.

The browser then opens `wss://dictate.natemunk.com/stream` with two WebSocket subprotocol values: `local-dictation.v1` and the signed ticket. Browser WebSocket APIs cannot attach the Access service-token headers directly, so the public transport route validates the same-origin `Origin`, signature, request UUID, mode, expiry, and fallback consent before forwarding the upgrade. It strips the ticket, adds the dedicated Worker-to-origin Access credentials, and selects only `local-dictation.v1` at the Mac. An unsigned, expired, malformed, or cross-origin request never reaches the tunnel.

Audio messages are little-endian signed 16-bit, 16 kHz, mono PCM and are bounded to 64 KiB each. Control messages are `finish` with a duration or `cancel`; server events are `ready`, `partial`, `final`, and `error`. The Worker transparently proxies frames and therefore has no audio buffer, transcript parser, Durable Object, or application storage. Cloud fallback is intentionally not attempted inside a failed socket: Dictation Inbox retains its complete M4A in memory and automatically submits it to `POST /v1/transcriptions`, where the existing fallback policy applies.

### `GET /v1/healthz`

Reports gateway availability only. It lives under `/v1` so the Cloudflare Access application protects it; the unprotected `/healthz` path no longer exists on the gateway and returns the standard `404 NOT_FOUND` envelope. The Mac origin keeps its own `/healthz`, which the Worker checks immediately before each transcription and never caches.

### History proxy

`GET /v1/history/manifest`, `GET /v1/history?revision=<n>[&cursor=<opaque>][&limit=1..100]`, and `POST /v1/history/operations` are transparent proxies to the same paths on the Mac origin. See [`../../docs/unified-history.md`](../../docs/unified-history.md) §3 for the DTOs, operation semantics, and result statuses.

All three require `X-Dictation-Client: pwa`; anything else is `400 INVALID_REQUEST`. The gateway validates before contacting the Mac:

- `revision` is required and must be a non-negative safe integer; `limit` must be 1–100; `cursor` must be at most 64 characters of `[A-Za-z0-9_-]`. Only these three parameters are forwarded.
- The operations body must be JSON of at most 2 MiB containing an `operations` array of 1–100 items, each an object with a non-empty string `op_id`, a `type` of `import`, `edit`, `pin`, `unpin`, or `delete`, and a non-empty string `entry_id`. A present `text` must be a string of at most 100 000 characters. Deeper semantics are the Mac's business and are reported per operation.

The proxy forwards the origin Access headers plus `X-Dictation-Client` and `X-Request-ID`. Timeouts are 10 s for the manifest and snapshot pages and 20 s for operations. History requests never run the Mac health pre-check and never invoke Workers AI.

A 2xx origin body is read with a 4 MiB bound, parsed once to confirm it is a JSON object, and then forwarded verbatim with the origin status, `Cache-Control: no-store`, and `X-Request-ID`. Failures map to the gateway envelope:

| Gateway status | `error.code` | Origin condition |
|---|---|---|
| 403 | `HISTORY_DISABLED` | `403 {"error":"history_disabled"}` |
| 409 | `HISTORY_CHANGED` (envelope also carries `revision`) | `409 {"error":"history_changed","revision":N}` |
| 400 | `INVALID_REQUEST` | gateway validation failure, or origin `400` |
| 413 | `PAYLOAD_TOO_LARGE` | gateway size limit, or origin `413` |
| 503 | `ORIGIN_AUTH_FAILED` | origin `401`/`403` without a history error body |
| 503 | `MAC_UNAVAILABLE` | timeout, unreachable origin, oversized or non-object body, any other status |

### PWA shell (`/app/`)

`GET`/`HEAD` for `/app` or anything under `/app/` is served from the Worker static-asset store; `/app`, `/app/`, and `/app/import` all serve `/app/index.html` so the fragment import route shares the shell. `/` returns a `302` to `/app/`. Any other method is `405`, unknown non-app paths keep the `404 NOT_FOUND` envelope, and `/v1/*` is never served from the asset store.

Every asset response carries:

- `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`
- `Referrer-Policy: no-referrer`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Permissions-Policy: microphone=(self)`
- `Cache-Control: public, max-age=31536000, immutable` for content-hashed filenames (`name.<8+ hex>.ext`) and `Cache-Control: no-cache` for HTML and every other asset.

`wrangler.jsonc` declares the asset store with `directory: "./public"`, `binding: "ASSETS"`, and `run_worker_first: true`, so no request can bypass the Worker. Because the Worker only serves `/app`-prefixed paths, PWA assets — including the service worker — must live under `public/app/`.

## Mac origin contract

The configured HTTPS origin must have no path, query, credentials, or fragment. The Worker sends a dedicated Cloudflare Access service token to both origin routes.

- `GET /healthz` must return HTTP 2xx with `{ "ready": true, "busy": false }` before audio is sent.
- `POST /v1/transcriptions` receives the raw audio body plus `Content-Type`, `X-Request-ID`, `X-Dictation-Mode`, `X-Dictation-Client`, `X-Allow-Cloud-Fallback`, and `X-Audio-Duration-Seconds`. It returns the Local Dictation response contract shown above, including `history_state`.
- `GET /v1/stream` upgrades only with `X-Dictation-Transport: stream-v1`, the `local-dictation.v1` subprotocol, and the same request/mode/client/fallback metadata. It consumes bounded PCM messages, emits optional live preview events, spools a temporary WAV, and returns the same final response contract after authoritative batch ASR.
- `GET /v1/history/manifest`, `GET /v1/history`, and `POST /v1/history/operations` receive `X-Request-ID` and `X-Dictation-Client: pwa` and answer with the history contract. No health check precedes them.

When cloud fallback is allowed, health failures, busy/not-ready responses, timeouts, non-2xx origin responses, and invalid origin payloads select Workers AI. The Worker makes at most one Mac transcription request and forwards a stable request ID so the origin can correlate or cancel work.

## Configuration and generated types

Copy `.dev.vars.example` to an ignored `.dev.vars` for local work and replace every placeholder. The public origin hostname is checked into `wrangler.jsonc`; the two origin Access credentials and independent stream-ticket signing secret must be stored as deployed Worker secrets and never belong in source control.

```sh
npx wrangler secret put MAC_ACCESS_CLIENT_ID
npx wrangler secret put MAC_ACCESS_CLIENT_SECRET
npx wrangler secret put STREAM_TICKET_SECRET
```

`worker-configuration.d.ts` is generated from `wrangler.jsonc` plus the variable names in `.dev.vars.example`. Regenerate and verify it with:

```sh
npm run cf-typegen
npm run cf-typegen:check
```

`wrangler.jsonc` uses only the approved `dictate.natemunk.com` custom domain and disables `workers.dev` plus preview URLs. The setup workflow refuses to deploy until you confirm that hostname is already behind Cloudflare Access. The iPhone Shortcut authenticates to that Access application using its own revocable service token. A separate token protects Worker-to-Mac origin access.

## Privacy and observability

The package declares only a Workers AI binding and a read-only static-asset binding for the PWA shell. It has no KV, D1, R2, cache, queue, Durable Object, Analytics Engine, or other persistence binding. Audio and transcripts live only for the request lifetime.

History request and response bodies are forwarded between the PWA and the Mac and are never stored, cached, inspected beyond a structural check, or logged. The Mac remains the only history store; Cloudflare is transport.

Structured logs use the request UUID supplied by the Shortcut/PWA to correlate one operation across the phone, Worker, and Mac. The remaining fields are a closed allowlist: event, route, client, mode, cleanup/history-state enums, HTTP status, coarse size/duration buckets, stable failure/fallback codes, and latency. They never contain exact sizes or durations, audio, transcript text, history entries, operation IDs, cursors, request headers, credentials, client IP, user agent, URLs/hostnames, origin response bodies, or exception messages.

Worker observability is explicitly enabled with full log sampling for this single-user service, persisted invocation logs, and query-string redaction so history cursors/search parameters do not appear in platform-generated request metadata.

For a failed PWA request, open **Settings → Diagnostics → Copy diagnostics** and find its `request_id`. Search that UUID in the Worker's **Observability → Logs** view, then match it in the Mac unified log:

```sh
log show --last 1h --style compact --predicate 'subsystem == "com.natemunk.LocalDictation" && category == "iphone_endpoint"'
```

The PWA keeps at most 100 diagnostic events in a separate local IndexedDB store. **Clear diagnostics** removes them. Diagnostic persistence is best effort and can never make a transcription fail.

## Verification

```sh
npm ci
npm test
npm run typecheck
npm run cf-typegen:check
npm run deploy:dry-run
npm run check:startup
```

Workers AI is remote-only. Unit tests inject deterministic Mac and cloud adapters, so they do not send audio or incur inference usage.
