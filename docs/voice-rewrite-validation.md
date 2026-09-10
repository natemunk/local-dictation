# Voice rewrite validation — September 10, 2026

This release extends the earlier clipboard-only popup documented in
`clipboard-rewrite-validation.md`. Source remains on main, based on
`e3ec7ed1037d7d592db747e09a820161a4f06cd6`, with all previous uncommitted work
preserved. No commit, push, Cloudflare deployment, or system-shortcut change occurred.

## Implemented behavior

- Idle Hyper+C snapshots the clipboard and starts separate instruction capture.
- During Hyper+D recording, Hyper+C requests a literal source finish into review;
  the message WAV ends and its destination is checked before instruction capture
  and popup activation. A second Hyper+C expands options without a timing window.
- Enter stops instructions; authoritative instruction ASR waits for source ASR.
  The resulting instructions and source are separate inputs to Apple's local
  writer. Model output is reviewed before Copy or revalidated original-target Paste.
- Source dictation keeps ordinary history behavior. Accepted Apple rewrites are
  identified as such; original text remains preserved. Explicit writing lacks a
  dictation-cleanup timing sample, so that metric is marked timing-incomplete.
- Canceling while source transcription is pending permits the original literal
  request to finish into Preview. Capture/model errors preserve the source and
  allow typed instructions or Review original. Instruction recording is capped at
  60 seconds; instruction ASR and model generation have 45-second cancellation limits.
- Instruction audio/text has no debug/history/sync retention. Temporary audio is
  deleted after ownership drains. Desktop capture preempts clipboard instruction
  work; the shared inference lease prevents a replacement batch ASR from running
  before canceled instruction ASR actually exits. Phone work is busy during capture/ASR.

## Verification performed

- Debug and production builds passed with Swift 6.3.3 and macOS SDK 26.5.
- 263 Swift tests across 37 suites passed on final source; 17 voice-flow tests
  include two separately enabled render/model checks that were explicitly run.
- Synthetic tests exercise source/instruction separation, source-before-instruction
  ASR ordering, second-press expansion, no automatic copy, stale callbacks,
  cancellation/audio cleanup ownership, empty input, recording/ASR limits,
  original-text recovery, held-D release, and inference lease drainage.
- The real Apple writing model processed a fake-recorder/fake-ASR voice flow with
  synthetic text in approximately 1.4 seconds of test wall time. A separate
  synthetic project-update model test also passed. These are smoke cases, not
  microphone, ASR-accuracy, or general latency benchmarks.
- Compact listening, compact result, and full options panels were rendered with
  synthetic text and inspected. Key/focus behavior in real applications remains
  a manual acceptance check; no real keys were posted to start capture.
- Privacy source audit, benchmark scorer fixtures, and whitespace checks passed.
  Worker/PWA tests were not rerun for this Mac-only feature.
- No microphone recording, real clipboard read/write, or transcript/history-content
  inspection was used during verification.

## Installed app evidence

The standard stable-signing setup workflow ran with a temporary six-idle-sample
guard immediately before replacement. The installed executable matches the signed
staging executable byte-for-byte and strict signature verification passed.

Installed/running executable:
`/Users/nmunk/Applications/Local Dictation.app/Contents/MacOS/LocalDictation`

SHA-256: `8e38e64c147467db7db3d9752718b82d476671c962df0854b671a7c7db115eef`

Previous app:
`/Users/nmunk/Library/Application Support/Local Dictation/Installed App Backups/Local Dictation previous 20260910-114138.app`

Post-restart local health: ready=true, busy=false, selected_engine=parakeetV2.
Existing signing identity and dictation settings were retained.

## First live acceptance check

1. Copy expendable text; Hyper+C; speak a short instruction; Enter; review; Cmd+Enter.
2. Hyper+D; dictate a message; Hyper+C; wait for Listening for instructions;
   speak changes; Enter; review; Cmd+Enter. Confirm only the revised message is
   pasted into the original field, and no instruction words are appended.
3. Repeat with a second Hyper+C to open presets, and Escape to cancel. Confirm
   source text survives while final ASR is pending and after it is ready.
4. Check held-D to C, input-device changes, quiet/empty instructions, app/Space
   switching, secure fields, and destination changes before Paste.
5. With approved live audio, verify desktop preemption and iPhone busy/retry
   behavior, live instruction partials, first-word capture, and eventual idle CPU.

These live recording/focus/shortcut checks were intentionally not performed by
the agent. The source, installed build, and actual device experience are separate
claims; a healthy endpoint does not establish live audio capture or partial results.
