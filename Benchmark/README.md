# Local Dictation final-engine benchmark

Two deliberately separate executables support final-engine evaluation:

- `local-dictation-corpus-runner` loads the same production final Parakeet/WhisperKit implementations as the app and writes candidate JSONL.
- `local-dictation-benchmark` is a Foundation-only scorer for precomputed JSONL. It does not load audio or run an engine.

The runner never selects the EOU/live-preview engine. EOU timing and quality remain a separate report and cannot enter final-engine selection.

The scorer emits pretty machine-readable JSON to stdout and a readable summary to stderr. It computes aggregate standard WER, 3x protected/ticket-weighted WER, aggregate RTF, median latency, nearest-rank p95 latency, hard gates, and the approved deterministic engine selection.

Run the synthetic verification:

```sh
Benchmark/verify-fixtures.sh
```

Run real manifest audio through an already installed final engine:

```sh
swift run local-dictation-corpus-runner \
  --manifest /path/to/corpus.jsonl \
  --output /path/to/parakeet-v2-results.jsonl \
  --candidate parakeet-v2
```

Normal runs are offline-only and fail the candidate when its Local Dictation-owned installation is missing or invalid. `--allow-model-preparation` is the sole runner flag that permits preparation/download. Every completed record atomically checkpoints the full valid JSONL at `<output>.partial`; successful completion atomically publishes `<output>` and removes the checkpoint.

Runner `latency_ms` is explicitly scoped as final-ASR file dispatch through authoritative final transcript. It is not stop-to-paste, cleanup, clipboard, or UI latency. Errors are path-redacted, and provenance records only a manifest-relative audio path or a safe filename label for an absolute manifest input. Candidate JSONL contains raw transcript hypotheses, so keep it local/private with the opt-in corpus; the aggregate scorer report omits transcript bodies.

See [corpus-schema.md](../docs/corpus-schema.md) for input contracts, exact formulas, CLI usage, selection semantics, and the explicit limitations of the synthetic fixtures.
