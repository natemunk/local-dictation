# Focused reliability slice — validation record

Implementation on `main`, based on `ae17bee3ac45`. The initial validation was
local-only; the user subsequently authorized commit, push, installation, and
restart after review fixes. No Cloudflare deployment is needed. Review the
three changes separately:

1. Cleanup admission/deadline controller, provider injection, cancellation
   propagation, and the in-memory Diagnostics state.
2. Nullable metrics v2, existing-upsert instrumentation, staged build identity,
   privacy contract, and read-only review queries.
3. Correct Last Dictation reference/menu action using the existing confirmed
   vocabulary-editing workflow.

## Automated and build checks

- Initial full Swift debug and release suites: 301 app tests in 41 suites plus
  five corpus-runner tests. Review follow-up adds source-level EOU cancellation
  ordering and caller-priority tests (303 app tests in 42 suites). The synthetic
  performance fixture is opt-in in release.
  The final debug and release functional suites pass. An optimized run with the
  performance fixture concurrently enabled tripped the existing rewrite AX test's
  100 ms timing/busy-window assertion; the full functional rerun and three isolated
  repetitions passed without changing rewrite code or its assertions. However,
  GitHub run 36154215696 subsequently reproduced both this issue and the cleanup
  test's 200 ms assertion without the benchmark enabled. Passing isolated runs
  did not establish CI reliability. Test-only follow-up replaces fixed provider
  sleeps with explicit gates, deliberately delays the caller 300 ms, and asserts
  timeout return while work remains blocked, busy rejection, and eventual release.
  Ten-second rescue bounds fail rather than hang on a broken implementation.
  Production deadlines and rewrite behavior are unchanged. Keep numerical
  performance measurements separate; the isolated reviewed-build fixture measured
  2.1% instrumentation overhead.
  The gated follow-up passed five consecutive full local suites with the
  performance fixture also enabled (303 app tests plus five corpus tests each).
- Synthetic iPhone tests exercise both production upload and streaming
  finalization paths: busy cleanup reports deterministic, and desktop preemption
  releases the remote ASR lease while cancellation-ignoring cleanup drains.
- Deadline tests cover caller cancellation, `URLError.cancelled`, provider
  success/failure/deadline races, late results, slot retention/release, and new
  refiner instances sharing one admission controller.
  Cleanup/preemption suites additionally passed five consecutive optimized
  repetitions. The tests explicitly await provider entry before asserting a
  draining state; cancellation before entry can correctly release immediately.
- Temporary SQLite tests cover fresh/existing migrations, legacy value/schema
  preservation, explicit column allowlist, nullable timing, redaction, stale
  revisions, analytics opt-out, Reset Analytics, and Delete Everything.
- Existing vocabulary tests plus new reference tests cover confirmation-based
  editing, malformed mappings, desktop/recovery eligibility, busy gating,
  deletion/retention, and refusing to substitute another entry.
- Privacy source audit, benchmark scoring fixtures, and `git diff --check` pass.
- The unchanged Home Base selector and savings calculation pass against a
  temporary synthetic v2 database using `verify-home-base-metrics.py`.
- Release app staging/signing verification checks identifier, arm64, macOS 15,
  entitlements/resources, and the existing designated requirement. The staged
  initial staged plist contained `0.1.0/ae17bee3ac45-dirty` without installing it.
  Reviewed builds now timestamp dirty labels; committed builds identify their
  Git revision. Installation uses the existing stable-signing setup workflow.

## Review follow-up

- Cancel the separately owned EOU-finalization task on every exit. Preserve the
  existing cancellation/current-session checks before recording ASR duration,
  using the timestamp immediately after transcription completes.
- Require admission injection for production refiners; preserve caller priority
  on detached provider/timer tasks. The separate rewrite feature is unchanged.
- Use committed delivery as the correction-reference eligibility gate instead
  of passing a hard-coded delivery status through a redundant switch.
- The EOU wiring regression is a source-order contract, not an end-to-end
  AppDelegate/audio test. Live acceptance remains required below.

## Performance scope

Repeated optimized synthetic short-cleanup fixtures compare the same production
deterministic pipeline with and without phase-clock/metric-value instrumentation.
Each run alternates six paired batches of 500 operations after warmup. Initial
runs measured approximately 0.5–3.4% overhead, below the 5% investigation threshold.
The metrics still use the existing upsert; no per-phase database writes were
introduced.

This is a component-level instrumentation guard, **not** a before/after installed
app trial, production ASR benchmark, or evidence of user-visible speedup. Real
microphone, AX, paste, model, and storage latency still need normal-use evidence.

## Rollout and remaining manual acceptance

- Commit/push and installation/restart were explicitly authorized after review.
- After installation, manually verify normal dictation, clipboard fallback,
  permissions, and the new correction dialog's cancel/confirm/reload behavior.
- Test real-device iPhone behavior if experimental cleanup is already enabled;
  the synthetic tests do not establish deployed/live-device acceptance.
- Keep current cleanup settings unchanged. Collect seven days of ordinary usage
  before choosing targeted application or accessibility changes. No automatic
  monitoring or new audio retention is configured.

## October 7 desktop milestone

Starting source: `884b1dc`; installed baseline: `0.1.0/2c31ef097faf`.
Frozen v2 review sample ends at 2026-10-07 14:42:15.771 UTC: 1,346 desktop
events, 1,322 paste-event posts, seven clipboard recoveries, 15 failed outcomes,
two cancellations. Delivered sessions have stop-to-paste-event median 186.8 ms
and p95 348.5 ms, and capture-ready median 81.1 ms/p95 161.2 ms. First-frame
timing is new and has no retrospective baseline. These are event outcomes,
not human accuracy/confirmed insertion scores.

- Readiness uses the first successful nonempty native frame published to the
  audio ring, an atomic timestamp, and the existing capture health cadence.
  The 150 ms notice checks actual arrival before display and is session guarded.
  No ready sound ships before AirPods acceptance; no idle microphone starts.
- Empty recognition is classified from captured frames and existing audio
  evidence as no frames, near-zero input, or audible input/no recognized speech.
  Near-zero energy is a recovery clue, not proof of device failure. Quiet speech
  that produces text is never discarded by this heuristic.
- Metrics v3 adds nullable first-frame time, fixed failure stage/reason, and
  coarse input transport. V2 migration fields are frozen and history-sync DTOs
  remain unchanged. Existing broad outcomes and latency meanings are retained.
  Copy Diagnostics uses schema 2 and includes the fixed last failure category;
  it never copies the dynamic error description shown in the UI.
- Signal is currently no-go for automatic insertion. Installed version 8.29.0
  has a reusable DOM composer, but a live AX conversation-token probe was not
  available. DOM identifiers do not prove macOS AX exposure. Even an editable
  Signal field is clipboard-only until conversation changes can be reliably
  detected. A secure-field sentinel remains non-insertable and triggers discard
  before ASR. No AXManualAccessibility setting is changed.
- Vocabulary correction offers selectable transcript text, an explicit mapping,
  a second confirmation before changing an existing mapping, and immediate
  config reload. It adds no clipboard inspection or transcript persistence.
- Desktop history has `(timestamp,id)` cursor browsing, 100-row pages, and only
  Pinned/Clipboard recovery filters. Search stays capped at 500, with an explicit
  all-history search label and disabled browse filters. Refresh handles deleted
  and edited rows, preserves drafts, fills bulk-insertion gaps, and avoids
  duplicate pages. Hidden/minimized windows skip reloads. Delete Everything
  synchronously clears their transient rows/drafts and cancels stale loads.
- Static rechecks found the earlier protected-span atomic alignment, secure
  deletion/VACUUM, retention, raw-history outage recovery, and generation cleanup
  paths. Existing suites exercise these; this is not a fresh exhaustive audit or
  real-device recertification of every historical review finding.

Before release, run optimized Swift tests, privacy audit, Home Base compatibility,
benchmark scoring fixtures, and signed bundle verification. Live microphone,
Bluetooth, wrong-conversation, dialog layout/confirmation, and real iPhone sleep
cases remain manual acceptance. The unchanged iPhone gateway/PWA suite and type
checks passed (338 tests); the integrated desktop suite passed 324 app tests plus
five corpus tests in release. Debug integration and offscreen native selection
also passed, including UTF-16 selection after emoji. Release instrumentation
fixture overhead was 2.3%; this is not a whole-app performance/accuracy claim.

After an approved install, collect seven days/preferably 500 attempts. Further
audio optimization is justified by first-frame p95 above 250 ms or confirmed
capture/device failures above 0.5% with a repeatable pattern. Compare existing
timing fields before/after; preserve device/duration grouping.

Vocabulary boosting remains off. Pinned FluidAudio 0.14.3 requires a different
sliding-window path and an extra CTC 110M model. Any future trial compares batch,
unboosted sliding-window, and boosted sliding-window with identical replacements.
CTC tokenizer/rescorer path ownership must be established first. Fresh audio and
explicit corpus review are required; no existing recordings or correction text
are silently exported. Phone acceptance separately covers awake, display sleep,
lid closed, long-idle sleep, preemption, and visible route accuracy.
