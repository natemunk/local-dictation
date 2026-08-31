# Changelog

This file records Local Dictation changes. The project is still in active v1
development and this tree does not claim a published, notarized Local Dictation
release.

## Unreleased

- Established the Local Dictation product identity while preserving the
  MIT-licensed Overwhisper seed attribution.
- Removed telemetry, Overseed service calls, cloud speech-to-text, Sparkle, and
  the inherited appcast and binary-release machinery.
- Made SwiftPM and the checked-in source-install helper the supported build
  path for the `LocalDictation` executable and `Local Dictation.app`.
- Added local FluidAudio and WhisperKit evaluation paths, explicit privacy
  invariants, configuration and profile contracts, safe delivery controls,
  history, and benchmark/acceptance artifacts.

## Upstream provenance

Local Dictation was seeded from Overwhisper commit
`b8ef86eb2fda65d7dcc68ab500fb371469c4d283`. The former `1.x` changelog
entries described upstream Overwhisper releases and are intentionally not
presented as Local Dictation releases. See `NOTICE` and `LICENSE` for the
preserved attribution and license terms.
