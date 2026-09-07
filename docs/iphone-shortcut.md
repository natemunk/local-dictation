# iPhone transcription shortcut

The optional iPhone endpoint records audio in Apple Shortcuts, sends it to the Access-protected gateway at `dictate.natemunk.com`, prefers Local Dictation on this Mac, and visibly falls back to Cloudflare Workers AI when the Mac is unavailable. The final text is copied on the iPhone and returned as Shortcut output.

The Shortcut is one of two iPhone clients. The other is the **Dictation Inbox** PWA at `https://dictate.natemunk.com/app/`, documented in [iphone-pwa.md](iphone-pwa.md). The Shortcut keeps the simple completed-file request described here; Dictation Inbox can additionally stream audio to the Mac while you speak and falls back to this same file route automatically. The PWA is also where unified history lives. They cooperate through the import link described under [Unified history handoff](#unified-history-handoff). The normative contract for both is [unified-history.md](unified-history.md).

## Privacy boundary

This feature is off by default and is separate from normal desktop dictation. Desktop microphone audio stays on the Mac. When the iPhone endpoint is used, the iPhone audio and returned transcript pass through Cloudflare on both routes. The `mac_local` route sends the audio through the tunnel to Local Dictation for local ASR. The `cloud_fallback` route additionally sends the audio to Workers AI. Neither route writes audio to Local Dictation history, Worker storage, KV, D1, or R2; optional local metrics contain only bounded labels, counts, and timing.

Transcript text is the one thing that changed. Settings → iPhone now offers **Unified iPhone History**, off by default. While it is off, the Mac persists no iPhone transcript and the history routes answer `history_disabled`, exactly as before. When you turn it on, the Mac saves iPhone transcripts in the same local SQLite history as desktop dictation, and desktop history entries transit Cloudflare while the PWA synchronizes. Cloudflare still stores nothing: the gateway proxies history requests to the Mac with no caching and no application storage.

The Shortcut, the PWA, and the Worker use three different Cloudflare Access service tokens, so each client can be revoked without disturbing the others. Revoke or rotate them independently in Zero Trust → Access → Service Auth → Service Tokens.

- **Shortcut gateway token** — replace both Access headers in every copy of the Shortcut.
- **PWA gateway token** — open the Dictation Inbox, choose Settings, clear the stored credentials, and paste the new pair. See [iphone-pwa.md](iphone-pwa.md).
- **Origin token** — rerun `npx wrangler secret put` from `cloud/iphone-gateway` for `MAC_ACCESS_CLIENT_ID` and `MAC_ACCESS_CLIENT_SECRET`.

## One-time Mac and Cloudflare setup

1. Install `cloudflared` and Node.js 20 or newer.
2. In Cloudflare Zero Trust, create two Self-hosted Access applications:
   - `Local Dictation iPhone Gateway` for `dictate.natemunk.com` with the application **path set to `/v1`**. Path scoping is what keeps the public PWA shell at `/app/*` reachable without credentials while every API route stays protected. Give this one application two Service Auth policies, each backed by a different service token: policy A for the Shortcut, policy B for the PWA.
   - `Local Dictation Mac Origin` for `dictate-origin.natemunk.com`, with one Service Auth policy backed by a third service token used only by the Worker.
3. Keep the Shortcut token for this document and the PWA token for [iphone-pwa.md](iphone-pwa.md). Setup requests all three pairs with hidden secret input so it can verify every policy; it persists only the origin pair as encrypted Worker secrets and does not save either gateway pair.
4. Open Local Dictation -> Settings -> iPhone, enable the localhost endpoint, and choose **Test Local Listener**. Keep Local Dictation running during setup. Requiring a live local `/healthz` response makes the final anonymous-origin probe conclusive instead of mistaking an offline origin for Access protection.
5. From the repository root, run:

   ```sh
   ./setup --configure-iphone-endpoint
   ```

6. Confirm that Settings still reports a ready listener, tunnel, and model.
7. If you want the iPhone and the Mac to share one history, enable Settings → iPhone → **Unified iPhone History** and read the disclosure it shows.

The setup command creates or reuses the named `local-dictation-iphone` tunnel, installs a per-user launch agent, routes the protected origin hostname, verifies the pinned Worker package, stores the origin token and a random stream-ticket signing secret as Worker secrets, and deploys the custom gateway hostname. It then runs ten checks: the PWA shell must load anonymously with a Content-Security-Policy header, gateway `/v1/healthz` and origin `/healthz` must both reject anonymous requests, each gateway token alone must reach gateway `/v1/healthz`, the origin token must not authenticate to the gateway, neither gateway token may authenticate to the origin, the origin token must reach origin `/healthz`, and public `/stream` must refuse a ticketless request. Setup stops with the failing check named rather than completing a weak configuration.

## Install the prebuilt Shortcut (recommended)

A signed, ready-to-import copy lives at [`shortcuts/Local Dictation.shortcut`](../shortcuts/Local%20Dictation.shortcut). It contains placeholder token text, never a real credential.

1. Open the `.shortcut` file on the Mac (double-click, or `open "shortcuts/Local Dictation.shortcut"`) and confirm **Add Shortcut**. iCloud syncs it to the iPhone.
2. In the Shortcuts app, open **Local Dictation** and paste your **Shortcut** gateway service-token client ID and secret into the two **Text** actions at the top (the comment above them explains which token). Never use the PWA or origin token here.
3. Run it once from the Shortcuts app to grant microphone access, then assign it to the Action Button or Back Tap.

The source is `shortcuts/build_local_dictation.py` (built with the `~/Shortcuts` builder). The prebuilt shortcut declares `X-Audio-Duration-Seconds: 600` because Shortcuts cannot read a fresh recording's duration; the Mac measures the real length after conversion and still enforces the ten-minute limit, so this only widens the request timeout.

## Build the Shortcut by hand

If you prefer to build it yourself, create a new Shortcut named **Local Dictation** with these actions in order:

1. Two **Text** actions holding the Shortcut gateway service-token client ID and secret.
2. **Record Audio**
   - Audio Quality: Normal.
   - Start Recording: Immediately.
   - Finish Recording: On Tap.
3. **Generate UUID**.
4. **Get Contents of URL**
   - URL: `https://dictate.natemunk.com/v1/transcriptions`
   - Method: POST.
   - Request Body: File.
   - File: Recorded Audio.
   - Headers:
     - `Content-Type`: `audio/mp4`
     - `CF-Access-Client-Id`: the client ID Text variable
     - `CF-Access-Client-Secret`: the client secret Text variable
     - `X-Request-ID`: UUID
     - `X-Dictation-Mode`: `clean`
     - `X-Dictation-Client`: `shortcut`
     - `X-Allow-Cloud-Fallback`: `true`
     - `X-Audio-Duration-Seconds`: `600` (see the note above)
5. **Get Dictionary Value** for `text` from Contents of URL.
6. **Get Dictionary Value** for `route` from Contents of URL.
7. **Get Dictionary Value** for `history_state` from Contents of URL.
8. **Copy to Clipboard** using `text`.
9. **If** `route` is `cloud_fallback`: **Show Notification** `Copied · Cloud fallback`; **Otherwise**: **Show Notification** `Copied · Mac`.
10. Add the unified-history handoff described in the next section.
11. End with **Stop and Output** `text` so other shortcuts can consume it.

Keep **Show When Run** off for the HTTP action after the Shortcut works. For Literal mode, duplicate the Shortcut and change `X-Dictation-Mode` to `literal` (and `mode=literal` in the handoff URL). To test Mac-only operation, temporarily set `X-Allow-Cloud-Fallback` to `false`; a Mac outage then returns an error and the Shortcut must not run **Copy to Clipboard**.

If Shortcuts labels the recording as `audio/m4a`, use that content type instead. Never put Access credentials in the URL, query string, Shortcut name, or notification.

## Unified history handoff

The Mac cannot always save an iPhone transcript. On the `cloud_fallback` route it never sees the text at all, and even on `mac_local` the save can be skipped or fail. The response therefore carries a `history_state` field, and the Shortcut hands the text to the PWA only when the Mac did not keep it.

| `history_state` | What it means | What the Shortcut does |
|---|---|---|
| `saved_on_mac` | The Mac already stored the entry under the same request UUID. | Nothing more. |
| `pending_device_sync` | Nothing is saved on the Mac. Always the value for `cloud_fallback`, and also returned when unified history is on but the save failed. | Hand off to the PWA. |
| `disabled` | Unified iPhone History is off on the Mac; nothing was or will be saved. | Hand off to the PWA, which queues the import until you enable the setting. |

Add these actions after **Show Notification**:

12. **If** `history_state` **does not equal** `saved_on_mac`:
    1. **Format Date** using the Current Date with the ISO 8601 format, then **URL Encode** the result. Both branches below need it.
    2. **Count** Characters in `text`.
    3. **If** Count **is less than or equal to** `16000`:
       - **URL Encode** `text`.
       - **Open URLs**:

         ```
         https://dictate.natemunk.com/app/import#v=1&id=<UUID>&ts=<encoded date>&mode=clean&route=<route>&client=shortcut&text=<encoded text>
         ```

    4. **Otherwise** (the text is longer than 16 000 characters), **Open URLs**:

       ```
       https://dictate.natemunk.com/app/import#v=1&id=<UUID>&ts=<encoded date>&mode=clean&route=<route>&client=shortcut&clipboard=1
       ```

       The PWA then shows a single **Import Copied Transcript** button that reads the clipboard when you tap it, because the text is already on the clipboard from step 8.

Use the same `UUID` from step 3 as `id`, and the same `route` value from step 6, so a later Mac-side save of the same request cannot create a duplicate entry.

Everything after the `#` is a URL fragment. Browsers and Shortcuts never transmit a fragment to a server, so the transcript reaches the PWA on the phone without passing through Cloudflare a second time. The PWA validates every field, stores the entry, queues an import operation, and replaces the address with `/app/` through `history.replaceState` before it renders anything, so the transcript does not linger in the address bar or in Safari history. A failed transcription never reaches step 12 and therefore never opens the PWA.

If you do not use the PWA at all, omit steps 12 and 13. The Shortcut then behaves exactly as it did before unified history existed.

## Triggers

- **Action Button:** Settings → Action Button → Shortcut → Local Dictation.
- **Back Tap:** Settings → Accessibility → Touch → Back Tap → choose the Shortcut.
- **Home Screen:** open the Shortcut details and choose **Add to Home Screen**.
- **Siri:** say the exact Shortcut name.

V1 intentionally copies the result. Inserting into whichever iOS field is focused would require a separately reviewed custom keyboard extension.

## Route and failure checks

- Mac app running, endpoint enabled, model ready: notification says `Copied · Mac`.
- App stopped, Mac asleep, tunnel stopped, model unavailable, or desktop dictation preempts the request: notification says `Copied · Cloud fallback` when fallback is enabled.
- Invalid token, malformed audio, unsupported media, duration over ten minutes, or body over 12 MiB: the request fails and the clipboard must remain unchanged.
- Workers AI unavailable after the Mac route fails: the request fails and the clipboard must remain unchanged.
- `history_state` is one of `saved_on_mac`, `pending_device_sync`, or `disabled`. A `cloud_fallback` result is always `pending_device_sync`. With Unified iPhone History off, a `mac_local` result is `disabled`.
- A failed request never opens the PWA: the handoff runs only after a successful response, so an authentication or validation failure leaves both the clipboard and the Dictation Inbox untouched.
- After a `saved_on_mac` result the entry appears in Mac history and in the PWA after its next sync, and no import operation is queued. After the other two states the entry appears in the PWA immediately and reaches the Mac when unified history is enabled and the Mac is reachable.

Cloudflare configuration, source tests, and an iPhone-generated M4A smoke test are separate evidence. Complete the real-device matrix before treating fallback as accepted.
