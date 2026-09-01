# Local Dictation v1 acceptance matrix

Snapshot: 2026-08-31. “Implemented” refers only to source in this checkout. “Automated-verified” refers to the 85-test SwiftPM run across 16 suites on this host. “Fixture-verified” refers only to synthetic scorer fixtures. “Pending” and “blocked” rows are not product claims.

## Evidence states

- **Required**: approved requirement, no implementation evidence asserted.
- **Source-observed**: matching source exists; build/runtime behavior is not established.
- **Automated-verified**: the named unit or contract test passed in the current checkout; real-app behavior may still require manual verification.
- **Fixture-verified**: a named synthetic/local check passed.
- **Pending manual**: requires app/device/user-flow exercise.
- **Pending benchmark**: requires fresh real corpus measurements.
- **Blocked**: current host defect prevents the intended verification path.

## Benchmark and corpus

| ID | Acceptance requirement | Evidence/method | Current state |
|---|---|---|---|
| BEN-001 | Manifest carries category, device, noise, duration, verbatim reference, protected tokens, provenance, and audio path. | JSON Schema plus CLI validation. | Fixture-verified with synthetic records. |
| BEN-002 | Corpus has at least 20 fresh opt-in recordings across all approved categories. | Corpus audit; no source-control audio assumption. | Pending benchmark; repository contains no real audio. |
| BEN-003 | Cleanup set has at least 10 separate raw-to-ideal pairs. | Cleanup schema and corpus count. | Pending benchmark; three synthetic structure examples are not the corpus. |
| BEN-004 | No existing Raycast recording is used without explicit recording-specific opt-in. | Provenance review and corpus inventory. | Required; bundled fixtures are synthetic only. |
| BEN-005 | Standard WER is aggregate `(S+D+I)/N`. | Pure Swift scorer and fixture report. | Fixture-verified. |
| BEN-006 | Protected vocabulary and ticket tokens carry 3x domain weight. | Weighted dynamic-programming scorer; protected substitution fixture. | Fixture-verified. |
| BEN-007 | RTF is aggregate processing/audio duration and fails above `0.20`. | Scorer gate plus forced-over-limit fixture. | Fixture-verified. |
| BEN-008 | Report includes median and nearest-rank p95 latency. | Scorer output and p95 assertion. | Fixture-verified. |
| BEN-009 | Crash, execution error, missing/empty result, explicit content loss, invalid timing, latency flag, and configured latency thresholds are hard failures. | Individual transformed fixtures. | Fixture-verified. |
| BEN-010 | Lowest weighted WER wins; within one point faster median wins; exact tie chooses Parakeet v2. | Passing-window and exact-tie fixture runs. | Fixture-verified. |
| BEN-011 | No passing candidate emits temporary Parakeet v2 and says to keep Raycast. | No-pass fixture; process exit 2 and JSON assertions. | Fixture-verified. |
| BEN-012 | Final report covers Parakeet v2/v3 and WhisperKit `small.en`/`large-v3_turbo` with exact versions/configuration. | Candidate-run provenance and report review. | Pending benchmark. |
| BEN-013 | Live-preview Parakeet EOU 320 ms and WhisperKit streaming are scored separately. | Separate live report and UI lag measurements. | Pending benchmark. |
| BEN-014 | Domain accuracy equals/exceeds paired Raycast results before cutover. | Paired opt-in recordings and locked normalization. | Pending benchmark; Raycast stays. |

## Controls, overlay, and insertion

| ID | Acceptance requirement | Evidence/method | Current state |
|---|---|---|---|
| UX-001 | Hyper+D key-down begins capture; <=350 ms tap arms toggle; >350 ms hold finishes on release. | Coordinator unit tests plus real event-tap timing. | Automated-verified for coordinator classification; real event-tap timing pending. |
| UX-002 | Second Hyper+D finishes toggle recording. | Coordinator unit and app integration test. | Automated-verified at coordinator boundary; real app integration pending. |
| UX-003 | Enter, Option+Enter, Shift+Enter, and Option+Shift+Enter map to approved modes/delivery. | Coordinator and event-policy unit tests plus app manual matrix. | Automated-verified for approved variants, numeric-pad origin, and pass-through of unsupported Return modifiers; manual matrix pending. |
| UX-004 | Any interleaved non-modifier typing permanently leaves all Enter variants to the foreground app for that session. | Unit test and Slack/terminal/manual app switching. | Automated-verified at coordinator boundary; manual evidence pending. |
| UX-005 | Finish Enter is swallowed, including repeats/empty recordings; no synthetic Return or auto-submit exists. | Event-tap integration and terminal/Slack observation. | Repeated finalization swallowing is automated-verified; real event-tap/manual evidence pending. |
| UX-006 | Escape always cancels active/in-flight work and discards temporary audio. | Unit plus temporary-file integration test. | Coordinator cancellation is automated-verified; app/file lifecycle is source-observed and manual integration remains. |
| UX-007 | Non-activating overlay never steals focus across apps, Spaces, or full-screen windows. | Manual matrix with focus logging. | Pending manual. |
| UX-008 | Destination/profile resolve at finish after arbitrary app switching. | Cross-app integration test. | Finish-time profile selection is automated-verified; real cross-app destination exercise pending. |
| UX-009 | Preview returns to captured destination or leaves clipboard safely if invalid. | Preview destination invalidation tests. | Automated-verified for editable destination capture and invalid/focus-lost clipboard fallback; real AX preview round trip remains pending. |
| UX-010 | Ten-minute warning and fifteen-minute forced preview. | Clock/state/configuration tests plus long-session manual run. | Fifteen-minute routing and rejection of configured caps above 900 seconds are automated-verified; warning and long run remain manual. |
| INS-001 | Clipboard+Command+V cutover path preserves all representations unless clipboard changed. | Rich clipboard integration tests. | Automated-verified against the macOS pasteboard for successful paste, pre-paste cancellation, and concurrent clipboard changes; cross-app rich-text matrix pending. |
| INS-002 | Paste failure retains transcript in clipboard/history. | Injected failure plus app manual matrix. | Automated-verified for synthetic paste failure and concurrent clipboard ownership; real-app failure/manual matrix pending. |
| INS-003 | Direct Accessibility insertion stays disabled per app until selection/rich-text/undo tests pass. | Settings/source audit and per-app matrix. | Required post-cutover. |

## Speech, cleanup, configuration, and history

| ID | Acceptance requirement | Evidence/method | Current state |
|---|---|---|---|
| ASR-001 | One 16 kHz mono stream feeds ASR and one temporary WAV. | Audio graph/source review and sample-format instrumentation. | Source-observed; device-level sample-format instrumentation pending. |
| ASR-002 | Finalized and volatile buffers replace rather than concatenate. | TranscriptBuffer unit tests and streaming engine fixture. | Automated-verified, including final commit clearing stale volatile text. |
| ASR-003 | Models may remain warm but perform no idle inference/polling. | Instruments plus network/process observation. | Pending benchmark/manual. |
| CLN-001 | Literal mode skips commands, inferred formatting, fillers, and model cleanup. | Cleanup unit corpus. | Automated-verified. |
| CLN-002 | Clean mode implements only the five approved initial commands and preserves unknown command-like speech. | Cleanup pair tests and history metadata assertion. | Automated-verified, including `scratch that` against ASR pause/segment boundaries. |
| CLN-003 | Refiner returns text; alignment validator rejects additions/substitutions/reordering and protected-span changes. | Positive/negative alignment corpus. | Automated-verified, including protected spans and deletion-volume limits. |
| CLN-004 | Two-second deadline falls back to deterministic output and marks `pasted_raw`. | Fake delayed refiner contract test. | Automated-verified at cleanup/history contract boundaries; end-to-end timing pending. |
| CFG-001 | Defaults and local TOML overrides merge with local precedence; invalid reload preserves last-known-good. | Configuration unit tests. | Automated-verified. |
| CFG-002 | Raycast vocabulary importer accepts only user-supplied comma-separated text and never reads Raycast storage. | Importer unit test and source audit. | Automated-verified. |
| CFG-003 | Native profile precedence uses bundle ID and AX role/subrole; generic browser fallback is safe. | Profile resolution unit matrix. | Automated-verified. |
| CFG-004 | Hostname profiles are opt-in, permission-denial-safe, and discard URL paths immediately. | Browser adapter contract and permission manual matrix. | Automated-verified at adapter/profile boundaries; real Automation permission matrix pending. |
| HIS-001 | Raw transcript is saved before cleanup/insertion in GRDB/SQLite FTS5. | Transaction-order integration and crash injection. | Source-observed with automated raw-recovery/history contracts; process-crash injection pending. |
| HIS-002 | 90-day retention, search, retry, delete-entry, and delete-all behave correctly. | Migration/search/clock tests. | Automated-verified. |

## Privacy and reliability

| ID | Acceptance requirement | Evidence/method | Current state |
|---|---|---|---|
| PRV-001 | No audio, telemetry, automatic updater, or cloud ASR traffic. | Dependency/source audit plus runtime network capture. | Static privacy audit passes; runtime network capture pending. |
| PRV-002 | Remote cleanup is explicit, text-only, allowlisted by `allow_remote`, and visibly Remote. | Request-body contract tests and UI/manual network capture. | Automated request/privacy contracts pass and UI is source-observed; live capture pending. |
| PRV-003 | Browser paths/hostnames never enter logs/history/refiner requests. | Adapter unit tests, database inspection, request capture. | Automated adapter/schema/request contracts pass; live request capture pending. |
| PRV-004 | Temporary WAV deletion and crash-orphan cleanup are reliable; debug retention is explicit and capped at 10. | File-system integration/crash tests. | Source-observed; launch/cancellation/crash file-system exercise pending. |
| PRV-005 | API keys remain in Keychain and are redacted from every artifact. | Keychain test double and repository/log scan. | Keychain storage and static source audit observed; end-to-end log/artifact exercise pending. |
| REL-001 | Sleep/wake and microphone unplug/switch recover without relaunch. | Repeated manual matrix on supported hardware. | Pending manual. |
| REL-002 | Zero lost raw transcripts in test week. | History audit across real use. | Pending cutover trial. |

## Quantitative performance gates

| ID | Gate | Measurement | Current state |
|---|---|---|---|
| PERF-001 | Hotkey key-down to overlay p95 `<=100 ms`. | Signposts over repeated real hotkey events. | Unbenchmarked. |
| PERF-002 | Deterministic-only median stop-to-paste `<=700 ms` for typical short dictations. | Warm-engine end-to-end corpus run. | Unbenchmarked; CLI uses 700 ms as provisional median ceiling. |
| PERF-003 | Local-refiner median stop-to-paste `<=1.2 s`. | Warm local-refiner end-to-end corpus run. | Unbenchmarked. |
| PERF-004 | Local-refiner p95 stop-to-paste `<=2.5 s`. | Warm local-refiner end-to-end corpus run. | Unbenchmarked; CLI uses 2500 ms as provisional p95 ceiling. |
| PERF-005 | Refinement never blocks deterministic fallback beyond configured two seconds. | Timeout contract and signposts. | Deadline cancellation is automated-verified; end-to-end signpost timing pending. |
| PERF-006 | Idle CPU over five warm minutes `<0.5%`, with no sustained inference/outbound traffic. | Instruments/activity/network capture. | Unbenchmarked. |

## Raycast cutover and v1 closure

| ID | Gate | Evidence | Current state |
|---|---|---|---|
| CUT-001 | Domain-vocabulary accuracy equals/exceeds paired Raycast. | Paired fresh corpus. | Pending; keep Raycast. |
| CUT-002 | Zero focus steals, accidental Enter submissions, lost raw transcripts, or terminal auto-submissions. | Manual app matrix and history audit. | Pending; keep Raycast. |
| CUT-003 | Interleaved typing always leaves Enter to foreground app. | Automated state test plus Slack/Ghostty exercise. | Automated-verified at coordinator boundary; runtime app exercise pending. |
| CUT-004 | Sleep/wake and microphone recovery require no relaunch. | Repeated manual recovery. | Pending; keep Raycast. |
| CUT-005 | Developer coworker with supported Apple Silicon/Xcode reaches first dictation via documented `./setup` in under 15 minutes. | Clean-machine timed source build. | `./setup` completed in an isolated temporary home on this host and produced a strict-code-sign-valid arm64 app with the expected bundle ID/minimum OS; fresh coworker timing and first dictation remain pending. Notarization is not required. |
| CUT-006 | One week and at least 50 real dictations achieve `>=90%` usable without re-dictation or Raycast fallback. | Local usage log and user review. | Pending; keep Raycast. |
| V1-001 | Live volatile/finalized transcript is complete. | Streaming engine/UI acceptance. | Source-observed with automated buffer/lifecycle contracts; live-model UI acceptance pending. |
| V1-002 | Opt-in hostname profiles satisfy permission/privacy matrix. | Chrome/Chromium and Safari manual/contract tests. | Automated adapter contracts pass; real Chrome/Safari permission matrix pending. |

## Current toolchain state

| ID | Observation | Evidence | Consequence |
|---|---|---|---|
| TOOL-001 | Host is macOS 26.6.2 with Xcode 26.6 (17F113). Normal `xcrun --sdk macosx --find swiftc` fails while loading `libxcodebuildLoader.dylib`: `CoreDevice.framework` references `_XPCTypeBool`, expected in `Mercury.framework`. | Reproduced during this benchmark work. | Normal developer-tool resolution is unreliable. |
| TOOL-002 | Direct SwiftPM invocation through the Xcode toolchain works when supplied the SDK plus Developer Framework search paths, even though `xcrun` remains broken. | Current run built the app and passed 85 tests in 16 suites. | Automated source contracts are usable on this host; the documented setup script contains the workaround. Repairing Xcode remains advisable for normal tooling. |
| TOOL-003 | Pure benchmark sources compile with direct `swiftc`, explicit SDK, target `arm64-apple-macosx15.0`, and a writable module cache. | `Benchmark/verify-fixtures.sh` passed. | Scorer mechanics are independently verifiable; this does not clear TOOL-001/002 for the application. |
| TOOL-004 | Source packaging puts required SwiftPM resource bundles under `Contents/Resources`, signs nested code before the app, and restores its generated dependency checkout. | Reusable app-bundle verifier plus isolated-home CI packaging with an explicit CI-only ad-hoc requirement. | Source implementation present; real per-machine identity creation and two-build TCC retention remain manual gates. Notarization and downloadable binary distribution remain deferred. |

## Manual application matrix still required

Exercise Ghostty, Slack, Linear, Chrome, Safari, Gmail, Notion, and Notes with app/Space switching, unrelated typing during recording, empty audio, rich text, selected text, endpoint outage, permission denial/revocation, sleep/wake, microphone unplug/switch, and long sessions. Record source revision, build command, OS/hardware, result, and any retained artifacts for each run.
