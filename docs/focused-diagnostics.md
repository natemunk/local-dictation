# Focused reliability diagnostics

Desktop behavior, speech engines, shortcuts, and paste policy are unchanged.
Optional model cleanup now has one app-owned admission slot shared by desktop
and iPhone. A deadline releases the caller promptly; it does not claim to stop
an uncooperative provider. Until that provider exits, later requests use
deterministic cleanup with `admission_busy`. Settings → Diagnostics → Optional
cleanup shows Idle, Running, or Draining and elapsed time as of Refresh. There
is no unsafe force-release button. The iPhone response still identifies the
actual cleanup backend; no API or Cloudflare deployment is required.

## Metrics v2 contract

`dictation_metrics_v2` adds nullable columns and sets newly written events to
schema version 2. Existing rows are not backfilled or relabeled. All durations
are monotonic seconds; unattempted/incomplete phases are NULL, not zero.

| Column | Meaning |
| --- | --- |
| hotkey_to_capture_ready_seconds | Coordinator's initial hotkey timestamp to existing capture-ready milestone; not first microphone frame (menu starts use their synthetic hotkey timestamp) |
| capture_stop_seconds | Synchronous stop-capture call |
| destination_capture_seconds | Existing AX destination capture, including retries |
| remaining_drain_wait_seconds | Remaining wait after destination capture; drainage can already be running |
| inference_lease_wait_seconds | Wait for remote ASR ownership to release |
| engine_transcription_seconds | Awaited production-engine transcription call |
| raw_history_write_seconds | Raw recovery-history write before cleanup |
| pre_delivery_history_seconds | Finalization/failed-polish history write before delivery |
| paste_validation_seconds | Existing destination validation and immediate recheck |
| stop_to_paste_event_seconds | Stop to immediately after posting Command+V, before history bookkeeping |

The original `asr_latency_seconds` still means Stop → ASR completion. The original
`stop_to_delivery_latency_seconds` still includes post-paste bookkeeping.
Do not add overlapping phases or compare old ASR values with the new inference
column as if their definitions were identical. Posting paste is not proof an
application accepted text.

Other additions are closed operational labels: `insertion_failure_kind`,
`insertion_tier`, `capture_outcome`, `cleanup_fallback_reason`, and `build_label`.
`foreground_bundle_identifier` is optional finish-time app identity, independent
of whether destination capture succeeded. It obeys destination-analytics opt-out,
is not copied by Diagnostics, and never authorizes insertion. Known secure-field
sessions remain excluded. No transcript, clipboard, URL, field contents, or
dynamic errors enter these columns. Remote events leave desktop timings unset.

Build labels are staged before signing as `version/revision[-dirty-UTCtimestamp]`; direct
development executables use `dev/unknown`. Neither bundle ID nor signing identity
changes. Reset Analytics and Delete Everything remove entire rows, including v2
fields. Retention remains unchanged.

## Read-only seven-day review

Open `~/Library/Application Support/com.natemunk.LocalDictation/history.sqlite`
using `sqlite3 -readonly`. These queries never select transcript tables.

```sql
SELECT build_label,
       CASE WHEN recording_duration_seconds IS NULL THEN 'unknown'
            WHEN recording_duration_seconds <= 30 THEN 'short <=30s'
            ELSE 'long >30s' END AS duration_bucket,
       delivery_outcome, insertion_failure_kind, capture_outcome,
       cleanup_fallback_reason, count(*) AS attempts
FROM dictation_metrics
WHERE completed_at >= datetime('now', '-7 days') AND source_kind = 'measured'
GROUP BY 1,2,3,4,5,6;

WITH samples AS (
  SELECT build_label,
         CASE WHEN recording_duration_seconds <= 30 THEN 'short <=30s'
              ELSE 'long >30s' END AS duration_bucket,
         stop_to_paste_event_seconds AS seconds
  FROM dictation_metrics
  WHERE completed_at >= datetime('now', '-7 days') AND source_kind = 'measured'
    AND recording_duration_seconds IS NOT NULL
    AND stop_to_paste_event_seconds IS NOT NULL
), ranked AS (
  SELECT *, row_number() OVER (PARTITION BY build_label,duration_bucket ORDER BY seconds) AS rank,
         count(*) OVER (PARTITION BY build_label,duration_bucket) AS n
  FROM samples
)
SELECT build_label,duration_bucket,max(n) AS samples,
       min(CASE WHEN rank >= n * 0.5 THEN seconds END) AS median_nearest_rank,
       min(CASE WHEN rank >= n * 0.95 THEN seconds END) AS p95_nearest_rank
FROM ranked GROUP BY build_label,duration_bucket;
```

Replace both occurrences of `stop_to_paste_event_seconds` in the second query
with a phase column from the table above to examine that phase. Missing old-build
measurements remain excluded. Interpret small samples and differences below 5%
cautiously. Application-level breakdowns require destination analytics opt-in
and remain local. Do not automatically upload these reports.

## Vocabulary convenience

Correct Last Dictation… reuses the existing personal vocabulary confirmation
dialog. It uses a persisted desktop history ID from this run, never the clipboard.
Recovery/preview entries are eligible; cancelled, empty, secure, and phone entries
are not. A deleted or expired entry is not silently replaced with another entry.

## Validation and rollout

The Home Base compatibility check is `scripts/verify-home-base-metrics.py`, run
with the Recall environment's Python. It imports the external reader unchanged,
uses only temporary synthetic databases, and verifies its allowlisted selection
and savings summaries before/after the added columns.

Installation, restart, commit, and push require explicit approval (now granted
for this slice). No cloud deployment is needed. After installation, verify permissions,
normal/clipboard delivery, and correction confirmation, then collect seven days
of ordinary usage before deciding whether to change accessibility execution.
