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
  repetitions passed without changing rewrite code or its assertions. Run the
  benchmark separately from timing-sensitive functional tests. Its isolated
  reviewed-build run measured 2.1% instrumentation overhead.
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
