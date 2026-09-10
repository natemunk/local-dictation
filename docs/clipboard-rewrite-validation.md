# Clipboard rewrite validation — September 10, 2026

## Implemented and installed

Hyper+C opens an independent floating writing panel. Seven curated presets plus
Custom instruction use Apple Foundation Models locally; result review and explicit
Copy are required. Drafts are memory-only. Dictation cancels rewriting, while stale
responses and overlapping rewrite generations are rejected. Ordinary dictation
cleanup, history sync, and the deployed Worker/PWA retain their separate boundaries.

Source remains on main, based on e3ec7ed1037d7d592db747e09a820161a4f06cd6, with
pre-existing uncommitted hardening work preserved. No commit or push was performed.

## Automated evidence

- Debug and production Swift builds passed with Swift 6.3.3 / macOS SDK 26.5.
- Full Swift suite: 246 tests across 36 suites passed.
- Fourteen new test functions cover request limits/boundaries, copy acceptance and
  failure, unavailable/busy handling, cancellation/drain/stale results, deadline,
  sanitized failure text, selection bounds, and synthetic Hyper+C event handling.
  Two functions are opt-in render/model smoke checks; both were explicitly run.
- The actual Apple model completed a synthetic project update in approximately
  1.3 seconds (test wall time), preserving the supplied test count and weekday.
  This is one smoke case, not an accuracy or latency benchmark for every preset.
- A synthetic panel render was inspected in light appearance. This does not prove
  real keyboard focus traversal or event-tap precedence alongside other apps.
- Privacy source audit, benchmark scorer fixtures, and git diff whitespace checks passed.
- No microphone recording, real clipboard read/write, or history-content inspection
  was used for validation. Worker/PWA tests were not rerun because those sources
  were not changed by this feature.

## Installed build

The standard setup workflow was run with a temporary wrapper requiring six
continuous idle health samples immediately before app replacement. Existing
stable signing was reused. The previous app was backed up at:

`/Users/nmunk/Library/Application Support/Local Dictation/Installed App Backups/Local Dictation previous 20260910-110240.app`

Installed executable:
`/Users/nmunk/Applications/Local Dictation.app/Contents/MacOS/LocalDictation`

SHA-256: `1dee360bbcf364e4acbc6850b7c67390414490cd018ae9ed40e1e506da63d933`

Installed executable matches the signed staging executable byte-for-byte. Strict
signature verification passed. The running process points to the installed app.
Post-restart local health returned ready=true, busy=false, selected_engine=parakeetV2.
No Cloudflare deployment or system shortcut change was made.

## Remaining manual acceptance

- Copy expendable text, invoke Hyper+C in Messages, Safari, and a custom editor;
  confirm that the Chinese conversion Service or Raycast does not intercept it.
  The menu-bar Rewrite Clipboard entry is the fallback. Apple documents the same
  chord for Traditional-to-Simplified Chinese conversion; local event-tap tests
  establish consumption, not global ordering against third-party utilities.
- Confirm Up/Down and Return operate the preset list; Tab reaches instructions;
  editor arrows/Return remain ordinary editing; Command+Return copies completed
  edits; Escape cancels first and dismisses when no generation is running.
- Verify app focus returns sensibly after Copy/Close and starting Hyper+D while
  the rewrite panel has focus. Test cancellation with a real desktop recording
  only after microphone approval, and a phone request only with user-provided audio.
- Review factual fidelity, tone, and formatting on representative real examples
  for all presets. Older macOS 26.0–26.3 relies on model context-error handling;
  26.4+ also preflights token capacity. Oversized inputs are never silently cut.
