# Local Dictation

Local Dictation is a local-first macOS menu-bar dictation app for Apple Silicon. Press Hyper+D, speak, and insert the transcript into the text field you were using. It is MIT licensed and does not require a subscription.

This repository is an active v1 implementation. The app builds and its automated unit/contract suite passes on the current development host, but the final speech-engine selection and Raycast cutover are deliberately **not claimed** until the checked-in benchmark and real-use gates pass.

## Privacy boundary

- Microphone audio always stays on the Mac.
- Speech recognition uses local FluidAudio or WhisperKit models only.
- First-time ASR and optional EOU-preview model downloads contact the documented model host, then models run from versioned Local Dictation-owned storage. Download requests contain no audio or transcript data.
- The app contains no telemetry SDK, cloud speech engine, Overseed service, or automatic updater.
- Deterministic cleanup is the default. An Advanced, off-by-default experiment may use Apple Foundation Models or an explicitly configured OpenAI-compatible `/v1/chat/completions` endpoint. A refiner receives transcript text, static rules, and transcript-derived allowed-deletion ranges only—never audio, destination app, browser data, field contents, or surrounding text.
- Non-loopback refinement endpoints require explicit `allow_remote = true` and show a persistent **Remote** badge.
- Temporary WAV files are deleted after ASR or cancellation. Debug audio retention is off by default.

Run `scripts/privacy-audit.sh` to check the source-level network boundary. The normative invariants are in [docs/privacy-invariants.md](docs/privacy-invariants.md).

## Controls

The global shortcut is Hyper+D (`Command+Control+Option+Shift+D`):

- Press and release within 350 ms to start toggle recording; press Hyper+D again to finish.
- Hold longer than 350 ms for push-to-talk; release to finish.
- Enter finishes in the active profile.
- Option+Enter forces Literal mode.
- Shift+Enter opens editable preview.
- Option+Shift+Enter opens Literal preview.
- Escape cancels and discards the session.

If you type any other key while recording, Enter immediately and permanently returns to the foreground app for that session. The overlay says `Typing detected · Hyper+D to finish`; Hyper+D remains the finisher. Local Dictation never synthesizes Return and cannot auto-submit a form or terminal command.

Insertion is deliberately conservative. Local Dictation posts Command+V only to the exact captured editable AX element or a reviewed same-focus-token app; otherwise it leaves verified text on the clipboard. It never uses a PID-only fallback or claims that posting a paste event proves an editor accepted it. Normal attempts leave ordinary text on the clipboard for clipboard-manager recovery. Optional **Private Clipboard Mode** adds best-effort concealed/transient markers. Secure fields discard the recording before batch transcription, history, or clipboard use. Terminal destinations are forced to Literal mode and automatic insertion removes every line break.

The overlay warns at 10 minutes. Recording stops at the hard 15-minute cap and opens preview instead of inserting automatically; configuration may shorten this cap but cannot extend it.

## Source build

Requirements:

- Apple Silicon Mac
- macOS 15 or newer
- Xcode 16 or newer, including Swift 6 or newer and the macOS 15 SDK
- Xcode Command Line Tools
- A working Git installation
- Internet access on the first setup run to fetch the pinned Swift packages
- Free disk space for SwiftPM package checkouts and build caches, plus roughly 600 MB for the default local speech model

From a fresh clone:

```sh
./setup --configure-signing
```

That first command explains and asks permission to create a ten-year, per-machine
local code-signing identity in the login keychain. It records only the public
label, certificate fingerprints, and designated requirement under
`~/Library/Application Support/Local Dictation/Signing/`; it never exports the
private key. Use plain `./setup` for later rebuilds. A normal setup fails closed
instead of silently falling back to ad-hoc signing.

The setup script:

1. Validates macOS, architecture, Xcode, SDK, Swift, and Git.
2. Resolves the pinned packages.
3. Runs the unit and contract tests.
4. Builds, resource-checks, and signs `Local Dictation.app` with the configured identity.
5. Verifies its identifier, architecture, entitlements, resources, signature, and designated requirement.
6. Installs it at `~/Applications/Local Dictation.app` and launches it.

Previous local builds are retained under `~/Library/Application Support/Local Dictation/Installed App Backups/` rather than beside the installed app, so Launch Services sees only one `com.natemunk.LocalDictation` application in `~/Applications` and a SwiftPM clean cannot erase the backup.

It works around the known local Xcode 26.6 `xcrun` private-framework mismatch by invoking the Xcode toolchain and macOS SDK directly when necessary. SwiftPM keeps its package checkout, cache, and build scratch data under `.build`, which can require substantial additional disk space beyond the app and model. It does not clear quarantine or pretend to notarize the build. Use `./setup --no-launch` in automation or `./setup --skip-tests` only when a test failure has already been investigated.

For signed-app packaging, `./setup` applies the narrow checked-in patch in `patches/` to the exact pinned `swift-transformers` checkout so its fallback tokenizer bundle resolves from the standard macOS `Contents/Resources` directory. The generated checkout is restored when setup exits; project source and the package lock are never rewritten.

On first launch, macOS asks for:

- Microphone access for local capture.
- Input Monitoring for Hyper+D and the Enter/Escape safety interlock.
- Accessibility for clipboard plus synthetic Command+V insertion.

After the first stable-signed install, setup guides one final removal and re-add of the old Microphone, Input Monitoring, and Accessibility rows. Later builds use the exact same certificate-backed designated requirement, and setup aborts if that identity drifts. Intentional replacement requires `./setup --rotate-signing-identity` and another one-time permission reset. Settings → General refreshes permission and Hyper+D listener health while it is visible.

No speech model is downloaded before you choose **Prepare & Finish Setup** in onboarding. Onboarding completes only after Microphone, Input Monitoring, Accessibility, the Hyper+D event tap, and the selected local model are all ready. That explicit action downloads the selected model from `huggingface.co` into `~/Library/Application Support/Local Dictation/Models/v1/`; the default model is roughly 600 MB, and later transcription remains local. Verify and Repair operate only on that owned model tree.

Browser Automation is not used or requested. Browser behavior is selected only by bundle ID, with no page URL or hostname access.

## Configuration

Editable TOML configuration is bootstrapped on first launch:

```text
~/.config/local-dictation/
├── app.toml
├── profiles.toml
└── vocabulary/
    ├── global.toml
    └── packs/
        └── symphony.toml
```

Local values override typed defaults. A malformed edit is rejected transactionally and the last-known-good snapshot—including its immutable, precompiled vocabulary—is retained. Persistent configuration diagnostics are shown separately from runtime errors. The Raycast importer accepts only a comma-separated string you explicitly paste; it never reads Raycast storage. Its `personal` pack is compiled and applied to every profile immediately after a successful reload. History can add a correction only after an explicit two-field confirmation; the app never learns vocabulary silently.

Runtime behavior is intentionally small: terminals use Literal mode, ordinary apps use Clean prose with explicit formatting only, and Linear uses Clean structured paragraphs with protected ticket IDs. Friendly app matches cover Slack, Notes, Notion, and generic browsers without duplicating policy. Legacy hostname settings are parsed as ignored values and surfaced as a configuration notice.

History is actor-isolated GRDB/SQLite with WAL and FTS5. Raw text is saved before cleanup/delivery for every nonsecure session; successful, failed, pending, and cancelled rows share the configurable 90-day default retention. Search falls back to escaped literal matching when an FTS query cannot represent punctuation.

## Benchmark

The repository includes a standalone scorer for:

- FluidAudio Parakeet v2 English.
- FluidAudio Parakeet v3 multilingual.
- WhisperKit `small.en`.
- WhisperKit `large-v3_turbo`.

Build and inspect it with:

```sh
swift build --product local-dictation-benchmark
Benchmark/verify-fixtures.sh
```

The synthetic fixtures verify scoring and selection mechanics only. They do not select an engine. Collect at least 20 fresh opt-in recordings and 10 raw-to-ideal cleanup pairs before invoking the real gate. See [Benchmark/README.md](Benchmark/README.md) and [docs/corpus-schema.md](docs/corpus-schema.md).

## Architecture

```text
Overwhisper/
├── App/             # lifecycle and orchestration
├── Audio/           # one 16 kHz mono capture and temporary WAV
├── Cleanup/         # commands, vocabulary, refiners, alignment validator
├── Configuration/   # TOML defaults, overrides, importer
├── Core/            # testable dictation state machine
├── History/         # GRDB, SQLite, and FTS5
├── Hotkey/          # global event tap and typing interlock
├── Output/          # destination capture and safe clipboard insertion
├── Profiles/        # bundle ID and AX role/subrole matching
├── Streaming/       # live finalized/volatile ASR adapters
├── Transcription/   # local final-ASR candidates
└── UI/              # non-activating overlay, preview, settings, history
```

Core dependencies are pinned in `Package.resolved`: FluidAudio, WhisperKit, GRDB, and TOMLKit.

## Status and acceptance

The full product requirements, corpus contracts, and acceptance matrix are checked in under [docs](docs). In particular, source compilation is not evidence that latency, accuracy, permissions, sleep/wake recovery, or the one-week Raycast cutover gates have passed.

## Origin and license

Local Dictation was seeded from audited Overwhisper commit `b8ef86eb2fda65d7dcc68ab500fb371469c4d283`. Attribution is preserved in [NOTICE](NOTICE) and [LICENSE](LICENSE). Both the original MIT-licensed portions and new Local Dictation work are distributed under MIT.
