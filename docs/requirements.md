# Local Dictation v1 requirements

Status: approved product requirements with implementation evidence annotated separately. This document does not claim that the app, an ASR engine, or a latency target has passed acceptance.

## Evidence and terminology

The normative source is Nate's approved Local Dictation v1 implementation plan from 2026-08-30. Repository evidence is deliberately narrower:

- The seed is the MIT-licensed Overwhisper repository at commit [`b8ef86e`](https://github.com/OverseedAI/overwhisper/tree/b8ef86eb2fda65d7dcc68ab500fb371469c4d283), with attribution preserved in [LICENSE](../LICENSE).
- [Package.swift](../Package.swift) currently identifies `LocalDictation`, targets macOS 15+, and pins WhisperKit `0.15.0`, FluidAudio `0.14.3`, GRDB `7.10.0`, and TOMLKit `0.6.0`. This is source state, not runtime proof.
- [DictationCoordinator.swift](../Overwhisper/Core/DictationCoordinator.swift) contains the intended phase vocabulary and control state machine. Its presence is not proof that every app integration path works.
- [TranscriptionEngine.swift](../Overwhisper/Transcription/TranscriptionEngine.swift) contains the streaming protocol and separate finalized/volatile transcript buffer. No live-engine benchmark has validated it.
- [Benchmark](../Benchmark) is independently compilable and its synthetic fixtures verify scorer mechanics only. The fixtures are not engine measurements.

“Required” below means approved behavior. “Observed” means present in the current checkout. “Verified” is reserved for a named test or measurement that actually ran.

## Product boundary

- The working product name is **Local Dictation**, repository name `local-dictation`, bundle ID `com.natemunk.LocalDictation`.
- V1 targets Apple Silicon and macOS 15 or newer.
- The app is a public, MIT-licensed, source-build macOS menu-bar application.
- Audio remains local. Telemetry, cloud speech-to-text, Overseed services, and automatic update checks are removed rather than hidden behind settings.
- Optional cleanup may use Apple Foundation Models or an explicitly configured OpenAI-compatible endpoint. A refiner receives transcript text and static cleanup rules only, never audio or destination context.
- Source-build sharing is sufficient for developer coworkers. Developer ID signing, notarization, and downloadable binaries are deferred; they are not silently simulated by clearing quarantine.

## Recording controls and state

The coordinator has these explicit phases: `idle`, `recording`, `finalizing`, `polishing`, `previewing`, `pasting`, and `failed`.

The global shortcut is Hyper+D (`Command+Control+Option+Shift+D`):

- Key-down while idle starts capture and displays the overlay immediately.
- Release within a configurable 350 ms leaves recording active in toggle mode.
- Holding longer than 350 ms selects push-to-talk and finishes on release.
- The next Hyper+D key-down finishes a toggle recording.
- Enter finishes in the resolved profile mode.
- Option+Enter forces Literal mode.
- Shift+Enter requests editable preview.
- Option+Shift+Enter requests Literal preview.
- Escape cancels and discards the active session.

Interleaved typing is a permanent session interlock:

- Hyper+D and modifier-only events do not count as typing.
- Any other non-modifier key marks `interleavedTyping`.
- From then until the session ends, every Enter variant belongs to the foreground app and cannot finish dictation. There is no inactivity re-arm.
- Hyper+D still finishes, Escape still cancels, and preview remains available from an overlay/menu action.
- The overlay shows `Typing detected · Hyper+D to finish`.

A finishing Enter must be consumed before the foreground application receives it, including empty recordings and repeats during finalization. V1 never synthesizes Return and exposes no auto-submit setting.

## Overlay and destination

- The overlay is a non-activating `NSPanel` that remains usable across Spaces and full-screen apps without stealing focus.
- It shows waveform feedback and the states `Listening`, `Polishing`, `Pasting`, `Pasted raw`, and failure information.
- Destination application and profile resolve when recording finishes, so the user may switch windows and applications while recording.
- Preview captures the focused destination before activating its editor. It pastes back only if the destination remains valid; otherwise the result stays on the clipboard.
- A ten-minute session warns. At fifteen minutes, capture stops and routes to preview rather than automatic insertion.

## Speech architecture and benchmark gate

- One 16 kHz mono stream feeds ASR while writing one temporary session WAV. Separate recorders are prohibited.
- Finalized and volatile text remain separate. A finalized update replaces the volatile range; the UI must not concatenate both and duplicate words.
- Models may remain warm, but idle mode performs no inference, polling, or sustained outbound activity.
- A waveform-only overlay is sufficient for the Raycast cutover. Live finalized/volatile text is still required to close v1.

Final-transcription candidates are:

- FluidAudio Parakeet v2 English.
- FluidAudio Parakeet v3 multilingual.
- WhisperKit `small.en`.
- WhisperKit `large-v3_turbo`.

Live-preview candidates are FluidAudio Parakeet EOU 320 ms and WhisperKit streaming. A live-preview winner may differ from the authoritative final engine.

The corpus contains at least 20 fresh opt-in audio/reference samples across technical vocabulary, corrections, enumeration, spoken commands, short dictations, two-minute passages, noise, and device changes. The cleanup corpus contains at least 10 separate raw-to-ideal pairs. Existing Raycast recordings are excluded unless Nate gives explicit opt-in for those recordings.

Final engine selection is mechanical:

1. Reject any candidate with a crash, content loss, aggregate RTF greater than `0.20`, or a latency-gate failure.
2. Find the lowest aggregate domain-weighted WER among passing candidates. Protected vocabulary and ticket identifiers carry 3x error weight.
3. Every passing candidate within one absolute WER percentage point of that minimum enters the speed comparison. Lowest median latency wins. An exact weighted-WER and median-latency tie chooses `parakeet-v2`.
4. If no candidate passes, set `parakeet-v2` as the temporary default and keep Raycast.

The exact implemented scoring definitions and provisional latency ceilings are in [corpus-schema.md](corpus-schema.md). A benchmark pass is necessary but not sufficient for Raycast cutover.

## Cleanup behavior

The required pipeline is:

```text
ASR transcript
→ explicit command parser
→ vocabulary and protected-pattern normalization
→ optional text refiner
→ alignment-diff validator
→ deterministic renderer
→ history
→ paste or preview
```

Literal mode applies only explicit vocabulary replacements and protected-pattern normalization. It skips spoken commands, inferred formatting, filler removal, and model cleanup.

Clean mode recognizes exactly these initial commands:

- `scratch that`: remove the current phrase since the prior VAD/sentence boundary.
- `new line`: insert one line break.
- `new paragraph`: insert two line breaks.
- `make that a bullet list`: format the current paragraph.
- `bullet list`: start explicit bullets in the current paragraph.

Unrecognized command-like language remains verbatim and is recorded as metadata. Deterministic filler removal begins conservatively with standalone terms such as `um` and `uh`; terms such as `like` and `you know` remain until corpus evidence approves a rule.

Refiners return ordinary cleaned text. The alignment validator then requires:

- URLs, email addresses, paths, identifiers, acronyms, and ticket IDs remain byte-identical, appear exactly once, and preserve order.
- Output lexical tokens are a case-insensitive subsequence of input lexical tokens.
- No new, substituted, or reordered lexical words.
- Case, punctuation, apostrophes, whitespace, line breaks, and bullet markers may change.
- Deletion only inside candidate disfluency ranges derived from fillers, correction markers, repeated starts, or ASR pause boundaries.
- Malformed alignment, excessive deletion, or any protected-span violation rejects the entire refinement.

Structured edit-plan generation is explicitly deferred unless later benchmark evidence supports it.

## Refiner policy

- `DeterministicRefiner` is the universal fallback.
- `AppleFoundationRefiner` is eligible in `auto` mode only on macOS 26+ when Apple Intelligence and the system model report availability.
- `OpenAICompatibleRefiner` uses a configured `/v1/chat/completions` endpoint and an optional Keychain credential.
- An explicitly configured endpoint overrides `auto`.
- Only loopback hosts count as local. Every other host requires `allow_remote = true` and a persistent Remote badge.
- The default refinement deadline is two seconds. Timeout or invalid output cancels refinement, delivers deterministic output, marks history `pasted_raw`, and offers retry only for that failed polish.

Availability, quality, and latency for both model-backed refiners remain unbenchmarked.

## Configuration and profiles

Editable configuration lives under:

```text
~/.config/local-dictation/
├── app.toml
├── profiles.toml
└── vocabulary/
    ├── global.toml
    └── packs/symphony.toml
```

- Bundled defaults merge with local overrides; local values win.
- Invalid edits retain the last-known-good configuration and surface a non-blocking diagnostic.
- A one-time importer accepts a user-supplied comma-separated Raycast vocabulary string and writes a personal pack. It never reads Raycast storage.
- Vocabulary supports literal phrases, deterministic replacements, protected terms, and patterns such as `MYE-` followed by digits forced uppercase.

Cutover profile matching uses bundle ID plus focused Accessibility role/subrole:

- Ghostty: Literal; commands and inferred bullets off.
- Slack: casual Clean; explicit bullets only.
- Linear native: structured Clean; conservative inference; ticket IDs protected.
- Apple Notes and native Notion: light cleanup with longer paragraphs.
- Browsers: generic paragraph-preserving Clean.
- Everything else: default Clean.

Hostname profiles are post-cutover v1 work. They are opt-in because Chrome/Chromium and Safari require per-browser Apple Events Automation permission. Denial falls back to the generic browser profile without repeated prompts. URLs are reduced immediately to hostname; paths never leave the adapter. Initial hostname matches are `chatgpt.com`, `claude.ai`, `mail.google.com`, `notion.so`, and `linear.app`.

## Insertion, history, and retention

- The cutover path uses clipboard plus synthetic Command+V.
- Every pasteboard representation is snapshotted and restored only if the user has not copied something else in the meantime.
- Paste failure leaves the result on the clipboard and in history.
- Direct `AXSelectedText` insertion is post-cutover and enabled per app only after rich-text, selection, and undo tests pass.
- Raw text is saved immediately after ASR and before cleanup or insertion.
- GRDB/SQLite with FTS5 stores timestamp, raw text, polished/delivered text, destination app, mode, delivery/refinement state and latency, and unrecognized command candidates.
- History never stores browser hostname or page information.
- Successful history retention defaults to 90 days and supports search, copy, repaste, raw-versus-polished inspection, failed-polish retry, delete entry, and delete all.
- Temporary audio is deleted after ASR or cancellation, and crash orphans are cleaned on launch. Debug audio retention is explicit and capped at the latest 10 recordings.

## Distribution and non-goals

The source workflow must eventually take a developer coworker with Xcode and Command Line Tools from fresh clone to first dictation through documented `./setup` steps in under 15 minutes. Notarized binaries remain deferred.

English is the only enabled v1 language. V1 excludes cursor-local or selected-text ingestion, silent vocabulary learning, auto-submit, arbitrary rerun modes, selected-phrase vocabulary hotkeys, numbered-list/quote/code-block commands, and implicit use of Raycast data.

## Unbenchmarked claims and host toolchain state

- No real audio corpus is included in this repository yet.
- No listed ASR engine is currently selected by real measurements.
- Accuracy, RTF, stop-to-final latency, model warm-up behavior, idle CPU, recovery, and cross-app reliability remain unverified.
- The synthetic benchmark fixtures prove arithmetic, gates, and selection behavior only.
- On this host (macOS 26.6.2, Xcode 26.6 build 17F113), normal `xcrun` resolution currently fails because `CoreDevice.framework` references `_XPCTypeBool`, which is absent from the loaded `Mercury.framework`. The documented setup fallback invokes the selected Xcode toolchain and SDK directly; it builds/packages the app and the full SwiftPM test suite passes. Repairing Xcode remains advisable for normal developer-tool behavior. See [acceptance-matrix.md](acceptance-matrix.md#current-toolchain-state).
