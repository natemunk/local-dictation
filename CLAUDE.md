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
./setup
# or, when launch is not wanted:
./setup --no-launch
```

`setup` resolves pinned dependencies, runs tests unless explicitly skipped,
builds the `LocalDictation` product, creates an ad-hoc-signed
`Local Dictation.app`, and installs it in `~/Applications`. Treat that
installation as a user-visible side effect.

## Privacy boundary

- Speech audio stays on the Mac and ASR uses the local FluidAudio or WhisperKit
  paths. There is no cloud speech engine.
- The app has no telemetry SDK, Overseed service integration, Sparkle updater,
  or automatic update check.
- Optional cleanup may call Apple Foundation Models locally or an explicitly
  configured OpenAI-compatible **text** endpoint. It must never send audio,
  destination-app context, browser location, focused-field contents, clipboard
  contents, or history.
- Non-loopback cleanup endpoints require explicit remote opt-in.
- `scripts/privacy-audit.sh` is a source audit, not proof of runtime network
  behavior.

The normative privacy contract is `docs/privacy-invariants.md`.

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
