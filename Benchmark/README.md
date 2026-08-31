# Local Dictation benchmark scorer

This directory contains a Foundation-only Swift CLI that scores precomputed ASR results. It does not load audio or run an engine.

The scorer emits pretty machine-readable JSON to stdout and a readable summary to stderr. It computes aggregate standard WER, 3x protected/ticket-weighted WER, aggregate RTF, median latency, nearest-rank p95 latency, hard gates, and the approved deterministic engine selection.

Run the synthetic verification:

```sh
Benchmark/verify-fixtures.sh
```

See [corpus-schema.md](../docs/corpus-schema.md) for input contracts, exact formulas, CLI usage, selection semantics, and the explicit limitations of the synthetic fixtures.
