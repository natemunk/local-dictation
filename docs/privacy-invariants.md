# Local Dictation privacy invariants

Status: normative v1 constraints. Unless a row cites completed evidence, it is a requirement to verify rather than a claim about the running app.

## Trust boundary

Local Dictation may handle microphone audio, transcript text, focused-application metadata, clipboard contents, local configuration, and local history. The default trust boundary is the user's Mac. Network access is limited to explicit model-artifact downloads from documented hosts and an explicitly configured text refiner under the policy below. Model-download requests contain no audio, transcript, destination, clipboard, or history data.

| ID | Invariant | Required failure behavior | Current evidence |
|---|---|---|---|
| PRV-001 | Speech audio never leaves the Mac. Cloud speech-to-text is absent, not merely disabled. | Refuse any ASR path that requires upload. | Cloud ASR source and dependency removal passes the static privacy audit; live network capture is pending. |
| PRV-002 | Outbound telemetry SDKs/services, Overseed service calls, and automatic update checks are absent. Local transcript-free SQLite metrics are not transmitted. | Build/release fails if a prohibited dependency or endpoint returns. | `Package.swift` and the source tree pass the prohibited-integration audit; runtime network behavior is still unverified. |
| PRV-003 | One temporary session WAV may exist only for active local ASR. | Delete after ASR or cancellation; delete crash orphans on next launch. | Lifecycle and orphan cleanup are source-observed; cancellation/crash file-system exercise is pending. |
| PRV-004 | Audio retention defaults off. Debug retention requires an explicit toggle and keeps at most the latest 10 recordings. | Refuse silent retention and provide a dedicated delete-retained-debug-sessions action. | Configuration default, explicit UI, cap, and whole-directory deletion (including orphan files and transcript metadata) are automated-verified; real retained-audio capture remains pending. |
| PRV-005 | Existing Raycast recordings are never imported or inspected without recording-specific opt-in. | Exclude them from corpus and app workflows. | Repository benchmark fixtures are synthetic and contain no audio files. |
| PRV-006 | A model-backed cleanup request contains transcript tokens and static cleanup rules only. It never contains audio, destination app, bundle ID, browser hostname/path, focused-field data, surrounding text, clipboard data, or history. | Reject request construction before transmission. | Apple and OpenAI-compatible request-boundary contract tests pass. Live request capture remains pending. |
| PRV-007 | Only loopback OpenAI-compatible endpoints count as local. Non-loopback hosts require `allow_remote = true`. | Reject the request and use deterministic cleanup when opt-in is absent. | Automated endpoint-policy tests pass, including non-loopback HTTPS and opt-in requirements. |
| PRV-008 | A configured non-loopback refiner displays a persistent Remote badge while active. | Do not hide or downgrade the indicator. | Badge state and UI are source-observed; runtime UI verification remains pending. |
| PRV-009 | API keys use the constant Keychain service `com.natemunk.LocalDictation` and never appear in TOML, history, logs, benchmark data, or diagnostics. Known development-service keys migrate only after the canonical write succeeds. | Omit/redact and leave the legacy item intact if secure migration fails. | Keychain identity, migration ordering, and migration-failure contract tests pass; end-to-end artifact/log verification is pending. |
| PRV-010 | V1 performs no browser Apple Events or hostname/URL access and requests no Browser Automation permission. | Generic browser behavior uses bundle ID only. | Browser adapter source/tests and the Apple Events usage description are removed; profile tests verify bundle-only matching. |
| PRV-011 | Legacy hostname configuration is decoded only to emit an ignored-setting diagnostic; it cannot affect runtime matching. | Preserve the last-known-good bundle profile and never request a URL. | Configuration tests verify ignored legacy values and fresh defaults contain no hostname setting. |
| PRV-012 | Browser hostname and page information have no runtime adapter, history schema field, refiner request field, or diagnostic field. | Reject any future boundary that introduces page context without a new reviewed privacy decision. | History-schema, profile-surface, and request-body contracts pass; live request capture remains pending. |
| PRV-013 | Raw and delivered transcript history is actor-isolated local SQLite/WAL data with 90-day retention for successful, failed, pending, and cancelled rows by default. | Purge expired rows at launch and daily; full-data deletion must clear history, metrics, and retained debug sessions, then checkpoint and rebuild the database files. | GRDB migrations, WAL health, concurrent actor access, all-state retention, FTS5/escaped search, whole-directory debug deletion, and persisted-marker scrubbing tests pass. |
| PRV-014 | Raw transcript is saved immediately after ASR, before optional cleanup or insertion, whenever history is healthy. | If history is unavailable, copy the immutable raw ASR result for recovery, surface a persistent warning, and continue delivery; cancellation must create no recovery artifact. | Source ordering and raw-recovery/history contracts are present; process-crash and injected live database-outage exercises remain pending. |
| PRV-015 | Normal insertion leaves ordinary transcript text on the clipboard. Optional Private Clipboard Mode adds best-effort concealed/transient markers. Secure destinations never read or write the clipboard. | Never overwrite a concurrent user copy; report only `pasteEventSent`, verified `clipboardOnly`, `historyOnly`, or `cancelled`. | macOS pasteboard tests verify persistent ordinary/private representations, secure refusal, paste failure, serialization, and concurrent clipboard ownership; cross-app integration remains pending. |
| PRV-016 | Idle means no microphone capture, ASR inference, refiner polling, telemetry, or sustained outbound traffic. Models may remain loaded. | Stop the offending work and surface a diagnostic. | Idle CPU/network measurements remain unbenchmarked. |
| PRV-017 | Logs and crash diagnostics exclude audio, transcript bodies, clipboard contents, URLs/hostnames, API keys, and focused-field content. | Redact or omit the event. | Custom transcript-bearing crash capture was removed; unified log calls reject dynamic `localizedDescription`; the static privacy scan passes. Runtime unified-log review remains pending. |
| PRV-018 | Corpus metadata uses non-identifying device classes/labels and provenance `synthetic` or `fresh-opt-in`; hardware serials and account identity are excluded. | Reject invalid manifest records. | The production runner enforces schema fields, approved categories/provenance, non-empty labels, safe IDs, and protected-reference alignment; schemas prohibit undeclared fields. Human provenance review remains required. |
| PRV-019 | ASR and optional EOU-preview models are downloaded only after an explicit user action from their documented model host into versioned Local Dictation-owned directories. Validation, quarantine, and repair never scan, mutate, or delete another application's model cache. | Keep an invalid owned installation quarantined, retry one clean owned download, and surface a durable error if repair fails. | Owned-manifest, path-containment, replacement, quarantine, repair, and stale-generation tests pass; live host/file-system observation remains pending. |
| PRV-020 | A finish-time secure AX destination causes the temporary recording to be discarded before batch ASR, history, clipboard, or synthetic paste. History Paste Again also refuses secure destinations without changing the clipboard. | Delete the WAV, clear live preview state, create no history row, and show `Secure field · recording discarded`. | Secure-role classification and no-clipboard repaste contracts pass; real secure-field and streaming-memory observation remain pending. |
| PRV-021 | Diagnostics and performance signposts contain operational state only: no transcript/clipboard text, audio, browser data, API key, destination/focused-field identity, raw path, or dynamic error body. | Keep diagnostics to a closed allowlist and signposts to fixed names with opaque correlation. | Sentinel non-leak, read-only history-health, fixed-catalog, and unrelated-copy tests pass; runtime Instruments/unified-log inspection remains pending. |
| PRV-022 | Local analytics store only integer counts, monotonic durations, wall-clock completion, bounded mode/engine/backend/outcome labels, and optional destination app identity. They contain no transcript, audio, URL, window/title/content, focused-field data, clipboard data, or dynamic error text. Secure-field sessions produce no metric. | Skip the event without affecting dictation if the schema/write fails; disabling analytics stops future events, and disabling destination analytics writes both destination fields as `NULL`. | Fresh/existing migration, forbidden-column, opt-out/redaction, revision-upsert, independent deletion/retention, and concurrent read-only access tests pass. The installed schema, legacy backfill, real measured rows, and Home Base's read-only no-content selection were verified; real secure-field and outbound-network observation remain pending. |

## Permitted local data flow

```text
microphone
  → in-memory 16 kHz mono stream
  → temporary local WAV
  → local ASR
  → raw local history
  → deterministic cleanup
  → optional text-only refiner
  → validated local text
  → clipboard/paste or preview
  → in-process word counting and transcript-free local metrics
```

Only integer counts—not transcript text—cross from the transcript-bearing pipeline into local analytics. Analytics and transcript history have independent deletion/retention controls and no foreign-key cascade. Home Base may open the database read-only but is not a runtime dependency.

The optional refiner is the only approved transcript-bearing network-capable runtime stage. It receives no ambient app context. On a fresh install the app does not initialize or download a speech model until the user chooses **Finish Setup & Download Local Model**; later model changes, verification, and repair are also explicit settings actions. First-time ASR and optional EOU-preview downloads contact the documented model host without sending user content. Model downloads must not be confused with transcription or cleanup traffic.

## Benchmark and corpus rules

- [Benchmark/Fixtures](../Benchmark/Fixtures) contains synthetic text/metadata only. Its `audio_path` values explicitly point to non-included files.
- A real benchmark corpus must be newly recorded with opt-in and stored outside source control unless a separate, explicit publication decision is made.
- References are verbatim ASR targets. Cleanup ideals belong in a separate cleanup-pairs JSONL file so polished text cannot leak into WER ground truth.
- Result `error` text must be sanitized before it is committed or shared.
- Production candidate JSONL necessarily contains raw transcript hypotheses and must remain local/private alongside the opt-in corpus unless a separate publication decision is made. It never embeds audio bytes.
- The aggregate scorer report contains scores and sample IDs, not transcript bodies, audio, or user identity.

## Remote cleanup consent

The following conditions are all mandatory before a non-loopback cleanup call:

1. The user explicitly configured the endpoint.
2. `allow_remote = true` is present in effective configuration.
3. The UI shows the persistent Remote badge.
4. Request construction has passed a privacy contract test.
5. Timeout or invalid response falls back locally without retrying another remote host.

There is no implicit cloud fallback.

## Verification rule

Source configuration, a unit test, a successful build, and a live runtime observation are distinct evidence. Privacy acceptance requires both source review and runtime network/file-system inspection. No current document may describe a privacy invariant as runtime-verified until that evidence is attached in [acceptance-matrix.md](acceptance-matrix.md).
