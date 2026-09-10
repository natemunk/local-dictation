# Dictation Inbox (iPhone web app)

Dictation Inbox is the optional web app served by the Local Dictation gateway at
`https://dictate.natemunk.com/app/`. It records dictation from the phone, shows one searchable
history that merges desktop and iPhone entries, and lets you edit, pin, delete, copy, and export
them. It is the second of the two iPhone clients; the Apple Shortcut, documented in
[iphone-shortcut.md](iphone-shortcut.md), remains the fastest way to dictate.

The normative contract behind everything below — the history schema, the API, the synchronization
algorithm, the token model — is [unified-history.md](unified-history.md). This document is the
user-facing guide.

The whole feature is optional. If you never open the PWA and never enable **Unified iPhone
History** on the Mac, nothing in this document applies to your install.

## What it does

- **Record.** Tap the record button, speak, then stop. On supported iPhones, audio starts moving
  to the Mac while you speak and live words can appear below the button. The normal phone
  recording continues in parallel and is submitted automatically if the live connection cannot
  finish. The gateway still prefers this Mac and visibly labels Workers AI fallback.
- **Read one history.** Desktop dictation and iPhone dictation appear in the same list, newest
  first, with full-text search. The first five entries appear initially; **Load more** adds five,
  and **Show all** opens the complete list. Search includes older entries.
- **Edit.** Correct a transcript without losing the original. Your edit is stored as a separate
  field; the raw and polished texts the engine produced are never overwritten.
- **Pin.** Pinned entries are exempt from retention pruning.
- **Delete.** Removing an entry on the phone removes it on the Mac too, once the two are in sync.
- **Copy and export.** Copy one entry to the clipboard, or export the visible list as text.

## Install it on the Home Screen

1. Open Safari on the iPhone and go to
   `https://dictate.natemunk.com/app/`. The page loads without any credentials.
2. Tap the **Share** button, then **Add to Home Screen**.
3. Name it *Dictation Inbox* and tap **Add**.
4. Launch it from the Home Screen icon. It now runs standalone, without Safari's address bar.

Installing is optional — the app works in a normal Safari tab — but standalone mode is what gives
it a full-screen layout and a stable place for its local data.

## Enter the PWA token

The app shell is public and contains no credentials. The API routes under `/v1/` are protected by
Cloudflare Access, so the app needs its own service token before it can do anything.

1. Use the **PWA gateway service token** — the third of the three tokens described in
   [iphone-shortcut.md](iphone-shortcut.md), the one bound to Service Auth policy B. Do not reuse
   the Shortcut token or the Worker's origin token.
2. In Dictation Inbox, open **Settings** and paste the client ID and the client secret.
3. Save. The app stores the pair in its own local database on the phone. The client secret stays
   hidden unless you select **Show**. **Remove key** removes the stored pair.

Getting the token onto the phone without emailing it to yourself: paste it into a note in a
password manager on the Mac and copy it from that app on the phone, or use Handoff's universal
clipboard. Nothing about the token should end up in mail, messages, or a shared note.

If the token is wrong or has been revoked, every API call fails and the app says so; recording and
the local cache keep working.

## Microphone permission

The first time you record, iOS asks for microphone access for `dictate.natemunk.com`. Allow it.

A standalone Home Screen web app keeps its own permission state, separate from Safari's. That has
two consequences worth knowing:

- Granting the microphone in the Safari tab does not grant it to the installed app. Expect to be
  asked a second time after you add it to the Home Screen.
- Some iOS updates reset permissions for standalone web apps, so the prompt can reappear later.
  This is an iOS behavior, not a sign that anything is wrong.

If you accidentally deny the microphone, go to Settings → Safari → Microphone (or long-press the
Home Screen icon and check its settings) and allow it again, then relaunch the app.

The app records with `MediaRecorder`, prefers the `audio/mp4` container, and enforces a 12 MiB /
10 minute ceiling. When AudioWorklet and WebSocket are available, it also downmixes and resamples
the same microphone stream to signed 16-bit, 16 kHz mono PCM in memory. A short-lived signed ticket
connects that stream to the Mac; the long-lived PWA credential is never placed in a WebSocket URL.
The Mac shows optional live preview from those frames, writes a temporary WAV, and still runs the
selected high-accuracy batch engine after Stop. If any live step fails, the completed MP4/M4A takes
the original file route without asking you to retry. On the rare iOS build that produces
`audio/webm` instead, the recording is sent with its real content type and the gateway rejects it
as unsupported; the app keeps the completed recording in memory and explains the failure.
Optional live-audio setup has a deadline so it cannot indefinitely block the normal recorder.
Audio is never written to the phone's local database and the microphone track is stopped when
a recording ends or fails.

If final transcription fails, **Retry recording** resubmits the same recording and request ID,
with the mode and cloud choice captured when it started. You can repair credentials in Settings
and then retry. **Cancel transcription** stops the current attempt but keeps the file;
**Discard recording** removes it. Starting another recording is disabled until this one succeeds
or is discarded. Keep this page open: reload, closing the app, or iOS reclaiming it loses this
memory-only audio. The completed-file backup is not a durable offline audio archive.

## What the badges mean

While recording, **Sending audio · waiting for Mac…** means the browser has queued audio
on the socket. **Mac is receiving audio…** requires a receipt from the Mac (or an actual partial
result from an older Mac build). Live words appear separately; successful audio delivery does
not guarantee preview-model availability. If live words are unavailable, recording continues and
final transcription still runs after Stop. **Recording · file upload backup** means live transport
failed; the complete recording will be submitted when you stop. A file upload can still be
transcribed on the Mac. Settings and entry details keep a visible **Stop recording** control.

The first upgrade from the older shell may require closing existing Safari tabs and the Home
Screen app once before reopening it. Subsequent available shell updates show **Update ready · reload**
only while the app is idle, with no
retained recording or unsaved edit. Apply it between dictations. There is no additional streaming
permission and no need to clear history or keys. Settings → Diagnostics → Copy diagnostics includes
the app build ID, fixed stream/ticket/capture failure codes, and audio-frame/partial counters without
audio or transcript text. A health check or socket upgrade alone does not prove live audio works.

Each entry carries a small set of badges.

| Badge | Meaning |
|---|---|
| **Desktop** | Dictated on the Mac with Hyper+D. |
| **Shortcut** | Dictated on the iPhone through the Apple Shortcut. |
| **PWA** | Dictated in this app. |
| **Mac** | The Mac's local engine produced the transcript. |
| **Cloud** | The Mac was unavailable and Workers AI produced the transcript on the visible fallback route. |
| **Not yet synced** | The entry, edit, pin, or deletion exists only on this phone so far. It uploads the next time the Mac is reachable. |
| **Conflict** | The same entry changed on the Mac and on the phone. Nothing is lost; you choose which version wins. |

An entry with no **Mac** or **Cloud** badge was dictated on the desktop, where the routing question
does not arise.

## How sync works

In plain language:

- **The Mac is the source of truth.** Its SQLite history is the real record. The phone keeps a
  cache of it so the list is instant and readable offline.
- **Completed text and saved changes are queued first.** Once transcription succeeds, its text
  is saved on the phone. Saved edits, pins, and deletions are committed with their queued operations
  before upload. An unfinished recording or an unsaved editor draft still requires the page to stay open.
- **Pending work uploads when the Mac is reachable.** The queue is sent first, then the app checks
  whether the Mac's history changed and refreshes its cache if so. Entries that have not been
  uploaded yet show **Not yet synced** and sit alongside the synchronized list.
- **Conflicts are shown, never guessed.** If an entry changed on both sides, the app marks it
  as changed on the Mac too and displays **Your change** and **On your Mac** side by side.
  **Keep mine** re-applies your version on top of the Mac's current one; **Use Mac's** discards your
  change and adopts the Mac's. There is no automatic merge or silent overwrite.
- **Unified iPhone History must be on.** If the setting is off on the Mac, the app shows a
  persistent notice. Recording still works and your entries stay queued, so turning the setting on
  later imports everything that accumulated in the meantime.

Syncing does not delete anything on its own. The only ways an entry disappears are your own
deletion and the retention rule below.

## Where things are stored

| Data | Where it lives |
|---|---|
| Transcripts, edits, pins | The Mac's local SQLite history — the authoritative copy. |
| A cache of that history, your pending operations, and the PWA token | IndexedDB inside the web app on this phone. Nowhere else. |
| Recorded audio | The fallback file and live PCM frames are held in memory only. Neither is written to IndexedDB, and the Mac deletes the streamed or uploaded temporary file after each request. |
| Worker application storage | No audio or transcript store: the Worker has no KV, D1, R2, Durable Object, queue, or API cache. Content-free operational logs are retained separately. Workers AI processes audio when cloud fallback is used. |

Audio and transcript text do transit Cloudflare, on both routes — that is the boundary you accept
by enabling the iPhone endpoint at all. On the fallback route the audio additionally reaches
Workers AI, and that route is always labeled **Cloud** in the list. When Unified iPhone History is
on, desktop history entries also transit Cloudflare while this app synchronizes; the Worker does not persist their bodies.

Worker and Mac logs correlate a request with the opaque UUID shown by the web app. They record
only fixed lifecycle phases, route/client/mode/cleanup enums, HTTP status, coarse size and duration
buckets, stable failure codes, and latency. They contain no transcript, audio, exact size/duration,
request body, token, URL, header, history content, or exception text.

When something fails, open **Settings → Diagnostics**. **Copy diagnostics** produces a report with
the last 100 safe events stored on this phone; **Clear diagnostics** removes them. The short request
reference shown beside an error matches the full `request_id` in that report and in the Worker/Mac
logs. Diagnostic storage is separate from transcript history and a logging failure never blocks
recording or transcription.

## Retention

Unpinned entries are pruned 90 days after they are created. Pinned entries are kept until you
unpin or delete them. Pruning happens on the Mac, and the phone's cache follows on the next sync.

## Offline

Without a network the app opens, shows the last synchronized list, and lets you search, read,
copy, and export it. Recording still works; if transcription fails, keep the page open and use
**Retry recording** once connected. No history entry is created until text is returned.
Edits, pins, and deletions you make offline are queued and marked **Not yet synced**, and they
upload the next time the Mac is reachable. The app never discards a queued operation because a
request failed.

History paging limits what is displayed; synchronization still refreshes the full saved copy when
the Mac history changes, preserving offline search and queued changes.

The app shell itself is cached by a service worker under a versioned name so it launches offline.
API responses under `/v1/` are never cached.

## Deleting things

**Refresh saved copy**, in Settings, refreshes the synchronized history cache. It preserves
pending results, queued changes, and the saved token.

**Remove all data from this phone** is a separate, confirmed action. It removes this app's local
history cache, pending results and changes, credentials, and diagnostics. Finish or discard any
recording first. It waits for any in-flight sync to finish so its response cannot repopulate the cleared
stores. Changes that already reached the Mac remain there; unsynced changes on this phone are lost.
After you set up the token again, sync can download the Mac's history again. It does not revoke the
token or delete the Mac's records.

**Deleting an entry** — swipe it, or use the entry's delete action — is the real deletion. It
removes the entry on the Mac as well, once the two are in sync.

Turning **Unified iPhone History** off on the Mac stops further remote persistence and makes the
history routes refuse. It does not delete anything that is already in the Mac's local history.

## Revoking the token

In Cloudflare Zero Trust → Access → Service Auth → Service Tokens, delete the PWA token. Because
the three clients hold three different tokens, this locks out this phone's web app immediately and
leaves the Apple Shortcut and the Worker-to-Mac path working. The app's cached entries stay on the
phone until you clear them. Use **Remove all data from this phone** while you still have the
phone. Revocation blocks future requests; it cannot remotely erase a lost phone's cached text.

## Known limitation

The PWA cannot paste into other apps. iOS gives a web app no way to insert text into whatever
field another app has focused, so Dictation Inbox copies to the clipboard and you paste. The same
limitation applies to the Shortcut; changing it would require a separately reviewed custom keyboard
extension, which is out of scope. If automatic copying fails, a visible dialog selects the text for
manual copying, including when you opened Copy from Settings or an entry detail.
