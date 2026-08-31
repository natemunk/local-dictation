# Benchmark corpus and result schema

Status: the scorer mechanics below are implemented and verified with synthetic fixtures. The corpus size, real engine measurements, and engine choice remain unbenchmarked.

## Files and formats

Each file is UTF-8 JSON Lines: one complete JSON object per non-empty line.

- Corpus records: [corpus-manifest-record.schema.json](../Benchmark/Schemas/corpus-manifest-record.schema.json)
- Candidate records: [candidate-result-record.schema.json](../Benchmark/Schemas/candidate-result-record.schema.json)
- Cleanup records: [cleanup-pair-record.schema.json](../Benchmark/Schemas/cleanup-pair-record.schema.json)
- Synthetic examples: [Fixtures](../Benchmark/Fixtures)

The examples contain no WAV files and no user or Raycast recordings. Their audio paths intentionally use `synthetic/not-included/...`.

## Corpus manifest record

```json
{
  "id": "fresh-technical-001",
  "audio_path": "audio/fresh-technical-001.wav",
  "category": "technical-vocabulary",
  "device": "built-in-microphone",
  "noise": "quiet",
  "duration_seconds": 8.42,
  "reference": "Create MYE-2077 in Linear for the Voshi release.",
  "protected_tokens": ["MYE-2077", "Linear", "Voshi"],
  "provenance": "fresh-opt-in"
}
```

Required semantics:

- `id`: unique, stable, non-identifying sample key.
- `audio_path`: local path to a synthetic or newly recorded opt-in sample. The scorer deliberately does not open it; the candidate runner owns audio decoding.
- `category`: one of `technical-vocabulary`, `correction`, `enumeration`, `command`, `short-dictation`, `two-minute`, `noise`, or `device-change`.
- `device`: non-identifying class or lab label. Do not include a serial number, account, or person's name.
- `noise`: controlled condition label. Suggested values include `quiet`, `office`, `fan`, `music`, and `outdoor`.
- `duration_seconds`: measured audio duration greater than zero.
- `reference`: verbatim spoken content before command interpretation or cleanup.
- `protected_tokens`: reference phrases whose words carry 3x domain weight. Every declared phrase must occur in the normalized reference.
- `provenance`: exactly `fresh-opt-in` or `synthetic`.

Ticket-shaped reference tokens matching a case-insensitive letter/alphanumeric prefix, a hyphen, and digits (for example `MYE-2077`) are automatically protected even if omitted from `protected_tokens`.

## Candidate result record

```json
{
  "sample_id": "fresh-technical-001",
  "candidate": "parakeet-v2",
  "transcript": "Create MYE-2077 in Linear for the Voshi release.",
  "processing_seconds": 0.61,
  "latency_ms": 145.0,
  "status": "ok",
  "content_loss": false,
  "latency_failure": false,
  "error": null
}
```

- There must be at most one result per `(candidate, sample_id)` and every `sample_id` must exist in the manifest.
- `processing_seconds` is total wall-clock transcription processing time for the clip. It drives RTF.
- `latency_ms` is measured consistently from the final input audio boundary to the authoritative final transcript. It drives median/p95 and the faster-engine comparison.
- `status` is `ok`, `crash`, or `error`.
- `content_loss` is set by runner/integrity checks for dropped or truncated material, especially missing beginnings/endings in long sessions. The scorer also treats a missing result or normalized-empty transcript as content loss. It does not guess subtle truncation from word count alone.
- `latency_failure` records an instrumentation-level timeout/stall/failure that aggregate numbers would hide.
- Crash/error text is optional and must be sanitized.

Use these canonical candidate IDs for the final-engine report:

- `parakeet-v2`
- `parakeet-v3`
- `whisperkit-small.en`
- `whisperkit-large-v3_turbo`

Score Parakeet EOU and WhisperKit streaming in a separate live-preview report so they do not enter the authoritative final-engine selection pool. Paired Raycast accuracy is also acceptance evidence, not a candidate in the final-engine selection input.

## Cleanup pair record

```json
{
  "id": "fresh-cleanup-001",
  "category": "correction",
  "mode": "clean",
  "raw": "I will update the draft scratch that I will update the requirements document",
  "ideal": "I will update the requirements document.",
  "protected_tokens": [],
  "provenance": "fresh-opt-in",
  "expected_validation": "accept"
}
```

Cleanup pairs never replace ASR references. They test command parsing, deterministic cleanup, and alignment validation after ASR. Maintain at least 10 fresh pairs across fillers, corrections, line/paragraph commands, bullets, protected terms, unrecognized command-like speech, and Literal mode.

## Text normalization and standard WER

[WERScorer.swift](../Benchmark/WERScorer.swift) uses one deterministic normalization for both metrics:

1. Apply Unicode canonical composition.
2. Extract Unicode letter/number words, retaining internal apostrophes, hyphens, and underscores.
3. Normalize curly apostrophes to ASCII apostrophes.
4. Lowercase with the `en_US_POSIX` locale.

Standard WER is corpus-aggregated:

```text
WER = (substitutions + deletions + insertions) / reference words
```

The dynamic-programming alignment is deterministic. WER may exceed 100% when insertions exceed the reference length.

## Domain-weighted WER

Every ordinary word has weight 1. Every word in a declared protected phrase and every ticket-shaped token has weight 3.

- Deletion cost is the reference-word weight.
- Insertion cost is the hypothesis-word weight, so hallucinated protected/ticket tokens are also penalized 3x.
- Substitution cost is the greater of the aligned reference and hypothesis weights.
- The denominator is the sum of reference-word weights.

```text
domain-weighted WER = weighted edit cost / weighted reference-word count
```

Candidate-level WERs are computed from summed corpus errors and denominators, not an average of per-sample WERs.

## RTF and latency

Aggregate real-time factor is:

```text
RTF = sum(processing_seconds) / sum(duration_seconds)
```

Any missing/invalid processing time fails the RTF gate. A complete candidate passes only when aggregate `RTF <= 0.20`; exactly `0.20` passes.

Latency is reported from all candidate sample values:

- Median is the middle value, or the arithmetic mean of the two middle values for an even sample count.
- P95 uses the nearest-rank method: sorted value at `ceil(0.95 × n)`, one-indexed.
- “Faster” in the selection rule means lower median `latency_ms`. P95 is a hard gate and report metric, not a second selection ranking.

The CLI defaults to median `<=700 ms` and p95 `<=2500 ms`, reflecting the approved v1 end-to-end deterministic median and outer local-refiner p95 ceilings. These defaults are provisional proxies for final-ASR scoring, not measured engine claims. Every report records the active thresholds, and callers can override them with `--max-median-latency-ms` and `--max-p95-latency-ms` once a benchmark-specific gate is approved.

An explicit `latency_failure`, missing/invalid latency, median above its limit, or p95 above its limit fails the latency gate.

## Hard gates and exact selection

Each candidate must pass all four gates:

1. No `crash` or `error` status.
2. No missing/empty result and no `content_loss` flag.
3. Complete aggregate RTF at or below `0.20`.
4. Complete latency data, no explicit latency failure, and median/p95 within configured limits.

Selection in [BenchmarkEvaluator.swift](../Benchmark/BenchmarkEvaluator.swift) is exactly:

1. If no candidate passes, emit `parakeet-v2` as `temporary_fallback_no_candidate_passed`, set `raycast_disposition` to `keep`, and exit 2.
2. Otherwise find the minimum domain-weighted WER.
3. Form a pool of passing candidates no more than `0.01` absolute WER (one percentage point) above that minimum.
4. Pick the lowest median latency in that pool.
5. If median latency ties, retain the lower weighted WER. If both weighted WER and median latency tie exactly (within `1e-12` arithmetic tolerance), choose `parakeet-v2` when present; otherwise use candidate ID order for deterministic output.

A passing report uses `raycast_disposition: benchmark_passed_other_cutover_gates_remain`; it does not authorize Raycast removal by itself.

## CLI

Compile without SwiftPM or application dependencies:

```sh
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
CLANG_MODULE_CACHE_PATH=/private/tmp/local-dictation-module-cache \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \
  -module-cache-path /private/tmp/local-dictation-module-cache \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  -target arm64-apple-macosx15.0 \
  Benchmark/*.swift \
  -o /private/tmp/local-dictation-benchmark
```

Score:

```sh
/private/tmp/local-dictation-benchmark \
  --manifest Benchmark/corpus.jsonl \
  --results Benchmark/results.jsonl \
  --json-output Benchmark/report.json \
  --summary-output Benchmark/report.txt
```

Without output paths, JSON goes to stdout and the readable summary goes to stderr. Exit 0 means a passing candidate was selected; exit 2 means the valid no-pass fallback report was emitted; exit 64 means arguments or input were invalid.

## Documented fixture verification

`Benchmark/verify-fixtures.sh` compiles the pure Swift sources with an explicit SDK and checks:

- standard versus protected-token-weighted WER;
- median and nearest-rank p95;
- a faster candidate winning while within one weighted WER point;
- an exact metric tie choosing Parakeet v2;
- crash, content-loss, RTF, and latency gates;
- no-pass fallback and Raycast retention.

Run:

```sh
Benchmark/verify-fixtures.sh
```

The benchmark executable is not a dependency of the existing SwiftPM test target, and changing `Package.swift` was outside this work's ownership boundary. Therefore no misleading Swift Testing wrapper was added. Pure scoring types remain separated under `Benchmark/`, and the fixture script is the documented verification path until the package target graph is intentionally changed.

## Real corpus readiness checklist

- At least 20 newly recorded, opt-in samples.
- Every required category represented, including a real two-minute integrity sample and a device-change run.
- At least 10 separate cleanup pairs.
- The same audio bytes and measurement checkpoints used for every candidate.
- Cold-start/model-download time recorded separately from warm transcription measurements.
- At least one integrity mechanism that can set `content_loss` for subtle long-session truncation.
- Candidate runner and exact model/version/configuration provenance attached to the report.
- Paired Raycast accuracy measured separately for the cutover criterion.

None of those real-corpus conditions has been completed by the synthetic fixtures.
