# Reliability hardening and validation

Source changes following the September 7, 2026 review, including the requested compact phone history.
The starting checkout was `main` at `e3ec7ed`, with ten uncommitted Safari/Worker fixes. Those changes
are preserved. This document describes the source implementation; it does not certify the installed
Mac app or deployed Worker. No install, settings change, commit, push, deployment, live microphone,
private transcript, or real clipboard exercise was performed for this implementation.

## Changes mapped to the review

| Review concern | Resulting behavior | Focused verification |
|---|---|---|
| Failed phone upload loses audio | Keep completed audio in memory until success/discard; Retry uses the same file, request UUID, mode, and cloud consent. Cancel keeps it recoverable. | Recording recovery and actual app-action tests; local storage failure retains visible text. |
| Fresh-result history actions disappear | Persist immutable imports and dependent edit/pin/delete operations atomically; send in order and overlay local intent during sync. | Actions before first snapshot, during import/snapshot, sequential local edits, conflicts, and pending deletion. |
| Canceled remote inference releases ownership too early | Drain preview/final work before releasing the remote lease; canceled sessions cannot start final inference later. | Synthetic streaming session with deliberately slow cancellation, overlapping Stop/preemption, and the actual lease coordinator. |
| Misleading phone reset | Separate nondestructive Refresh saved copy from confirmed Remove all data from this phone. Require capture/retry to finish or be discarded first; drain sync before removal. | Real fake-IndexedDB transactions, in-flight sync/reset, queued text/key removal, and blocked removal during transcription. |
| Mac edits overwrite concurrent changes | Capture revision and draft identity; retain newer typing or conflicting drafts after asynchronous Save. | Revision conflict, save completion ownership, and typing while Save is pending. |
| Streaming label overstates success | Separate sending from Mac receipt; additive content-free audio counters and preview-unavailable events; retain final batch transcription. Bound socket buffering. | PCM receipt and failed-preview session tests, protocol compatibility and backpressure tests. |
| Optional capture/request can hang | Bound AudioWorklet preparation/resume, optional recorder attachment, and API requests through response bodies; ignore late results. | Hanging module/resume/close/fetch tests and canceled attachment/socket tests. |
| Copy hides recovery | Phone manual-copy dialog appears above sheets. Mac Copy failure keeps the same editable preview and an inline notice. | Actual app-action DOM harness and injected failing Mac clipboard writer. |
| Desktop watchdog discards useful text | Use duration-aware engine budget; recover raw/partial text into review-only preview; admit only one recovery owner. | Deadline policy and session recovery ownership tests; no commands or automatic cleanup from partial recovery. |
| Consent/crash lifecycle gaps | Check consent generation in the database transaction; invalidate old requests on off/on. Revisit only unchanged launch-time audio orphans. | Consent revocation and synthetic orphan identity/age tests. |

Additional small improvements: visible phone Stop outside the main screen; idle-only shell update
prompt and build ID; visible comparison of conflicting text; longer honest clipboard/history fallback
messages; newest words in the Mac overlay; preferred-microphone fallback disclosure; hardware capture
stopped before bounded focus inspection; Worker deadlines through body consumption.

The phone initially renders five recent history rows. **Load more** adds five; **Show all** expands
the list. Search covers the full cached history, and clearing it restores the previous browsing depth.
This limits DOM work and scrolling. It does not limit the underlying IndexedDB reads or the complete,
atomic history snapshot downloaded when the Mac's revision changes. That protocol remains intact to
preserve reliable deletion, conflict, and offline behavior.

## Automated and safe runtime checks

- Fresh Swift build and suite: **232 tests across 35 suites passed**, including repeated cancellation through preview reset.
- Worker/PWA suite: **338 tests across 19 files** (112 Worker, 226 PWA); gateway, gateway-test, and PWA TypeScript checks.
- Static privacy audit and benchmark fixture scorer. Fixtures verify scoring mechanics; no speech accuracy or real latency claim follows from them.
- Browser smoke test at **390 × 844**, served from a temporary loopback origin with synthetic history and synthetic credentials. Verified five initial rows, Load more to ten, Show all to thirteen, search finding an older item, and readable Settings. No horizontal overflow or browser console errors. The test used current assets with a fixture-only bootstrap; no real endpoint, microphone, clipboard, or credential was used.
- CI now runs the Worker/PWA suite and TypeScript checks. Vitest disables remote bindings; deterministic adapters handle all tests without a Cloudflare binding session or live inference.

The service worker now waits for an idle user-requested update. When moving from an older cached
shell that lacks that UI, close existing Safari tabs/Home Screen app windows once and reopen. No
history/key reset is needed. Do not force-refresh an active or recoverable recording.

## Remaining real-device acceptance

After an explicitly approved Mac installation and Worker/PWA deployment, test both Safari and the
Home Screen app with approved, non-sensitive speech. Record the source/build/Worker versions and
keep the test text private.

1. While still recording, confirm increasing Mac audio-receipt counters and nonempty partial words;
   then Stop and verify final batch text. A successful upgrade, health probe, or sending status is
   insufficient. Repeat with cold/unavailable preview and an older-compatible Mac build if needed.
2. Drop/restore connectivity, expire/reject credentials, cancel transcription, and retry the retained
   file. Verify the same UUID and no duplicate history row. Closing/reclaiming the page still loses
   memory-only audio; iOS can suspend timers while backgrounded.
3. Interleave desktop Hyper+D with phone recording/finalization. Desktop remains first in line for
   final inference; canceled remote inference must have exited before its lease is released.
4. Exercise allowed/refused cloud fallback, immediate result edits/pins/deletes, cross-device
   conflicts, manual-copy recovery, shell upgrades, and five-row history browsing with real volume.
5. On Mac, exercise app/Space switching, secure fields, clipboard managers, microphone fallback,
   and long-session recovery. Observe that microphone capture stops at Finish before focus retries.

## Performance follow-up

Measure warm and cold recording startup, first actual partial, Stop-to-final, and Stop-to-paste
separately. Existing Mac signposts and new bounded phone diagnostics provide content-free evidence.
No model switch or ASR quality tradeoff was made. The test runner's remote binding session is removed,
stream buffering is bounded, and initial history DOM size is bounded to five rows.

If large histories still make sync slow after measuring on the phone, design incremental history
sync separately with deletion tombstones and revision coverage; simply downloading only the first
page of the current full snapshot would corrupt its replacement semantics. Likewise, defer a custom
iPhone keyboard, storage redesign, new framework, or Durable Object until a measured need justifies it.
