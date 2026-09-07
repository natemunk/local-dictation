# CLAUDE.md

This file gives coding agents repository-specific guidance for Local Dictation.

## Identity and provenance

- The product, Swift package, executable, and app bundle are **Local Dictation**.
- The `Overwhisper/` source directory remains for seed-history continuity; it is
  not the current product name.
- Local Dictation was seeded from MIT-licensed Overwhisper commit
  `b8ef86eb2fda65d7dcc68ab500fb371469c4d283`. Preserve the attribution in
  `NOTICE` and `LICENSE`.
- This is an active v1 implementation. A successful source build is not proof
  that engine selection, latency, accuracy, permissions, or cutover gates have
  passed.

## Build and validation

SwiftPM is the primary project definition. `Package.swift` is canonical for
targets and dependencies; `project.yml` is optional XcodeGen input. Do not
restore or hand-edit a checked-in generated `.xcodeproj`. Open `Package.swift`
in Xcode when an IDE is needed.

```sh
just build
just test
just privacy-audit
just benchmark-fixtures
```

The `Justfile` accepts `LOCAL_DICTATION_SWIFT=/absolute/path/to/swift` when
the active `xcrun` shim is broken. It also uses a repository-local SwiftPM
cache and disables SwiftPM's nested sandbox for agent environments.

For the documented end-to-end source install, run:

```sh
./setup --configure-signing # first install on a Mac
./setup                     # subsequent rebuilds
# or, after signing is configured, when launch is not wanted:
./setup --no-launch
./setup --configure-iphone-endpoint # optional Cloudflare/Shortcuts path
```

`setup` resolves pinned dependencies, runs tests unless explicitly skipped,
builds the `LocalDictation` product, creates a stable per-machine-signed
`Local Dictation.app`, and installs it in `~/Applications`. Treat that
installation as a user-visible side effect.

## Privacy boundary

- Desktop speech audio stays on the Mac and desktop ASR uses the local
  FluidAudio or WhisperKit paths.
- The opt-in iPhone endpoint is a separately disclosed boundary: iPhone audio
  and returned text transit Cloudflare, and visible fallback may use Workers AI.
  It stores no remote audio anywhere and nothing at all in Worker storage.
- Settings → iPhone → **Unified iPhone History** is a second, independently
  opt-in boundary and is off by default. While it is off, no remote transcript
  is persisted and the history routes return `history_disabled`. While it is on,
  iPhone transcripts are saved in local history and desktop history entries
  transit Cloudflare during iPhone web-app synchronization without being
  persisted there. Disabling it deletes nothing.
- The app has no telemetry SDK, Overseed service integration, Sparkle updater,
  or automatic update check.
- Optional cleanup may call Apple Foundation Models locally or an explicitly
  configured OpenAI-compatible **text** endpoint. It must never send audio,
  destination-app context, browser location, focused-field contents, clipboard
  contents, or history.
- Non-loopback cleanup endpoints require explicit remote opt-in.
- `scripts/privacy-audit.sh` is a source audit, not proof of runtime network
  behavior.

The normative privacy contract is `docs/privacy-invariants.md`. The unified
iPhone history slice — history schema, history API, synchronization
algorithm, PWA constraints, and the three-service-token model — is
normatively specified in `docs/unified-history.md`; the user-facing guides
are `docs/iphone-shortcut.md` and `docs/iphone-pwa.md`.

## Architecture

Local Dictation is a menu-bar app. The main flow is:

1. `HotkeyManager` observes Hyper+D and the typing safety interlock.
2. `DictationCoordinator` owns the tap/hold and session state machine.
3. `AudioRecorder` captures microphone input through an input-only AUHAL path.
4. Local transcription produces finalized and volatile text without
   concatenating revisable partials.
5. The cleanup pipeline applies the selected profile and privacy policy.
6. Preview or `TextInserter` delivers the accepted text to the captured
   destination.

Configuration, profiles, history, and benchmark contracts live in their
corresponding source directories and checked-in docs. Keep source behavior,
tests, requirements, and acceptance status distinct.

## Release status

The repository currently documents a source-build workflow only. It has no
Sparkle appcast, notarized-DMG workflow, or automatic release script. Do not
commit, tag, push, publish, sign for distribution, or claim a downloadable
release without an explicit release plan and authorization.

When versioning is eventually authorized, keep the version sources used by
`project.yml` and `setup` aligned and review the resulting diff before any
Git operation.
