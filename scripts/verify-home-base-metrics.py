#!/usr/bin/env python3
"""Synthetic, read-only consumer compatibility. Never opens the user's DB."""
import importlib
import pathlib
import sqlite3
import sys
import tempfile
from zoneinfo import ZoneInfo

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else
                    "/Users/nmunk/work-projects/symphony/recall")
sys.path.insert(0, str(root / "src"))
reader = importlib.import_module("recall.app.dictation")

def read(path):
    with reader._connect_read_only(path) as connection:
        columns = reader._resolve_columns(connection)
        rows = reader._read_metric_rows(connection, columns)
        return columns, [dict(row) for row in rows], [
            reader._event_from_row(row, columns, ZoneInfo("UTC")) for row in rows]

with tempfile.TemporaryDirectory(prefix="ld-home-base-compat-") as temporary:
    path = pathlib.Path(temporary) / "synthetic.sqlite"
    with sqlite3.connect(path) as connection:
        connection.executescript("""
            CREATE TABLE dictation_metrics (
              completed_at TEXT, recording_duration_seconds REAL,
              raw_word_count INTEGER, delivered_word_count INTEGER,
              asr_latency_seconds REAL, cleanup_latency_seconds REAL,
              stop_to_delivery_latency_seconds REAL, delivery_outcome TEXT,
              source_kind TEXT, schema_version INTEGER);
            INSERT INTO dictation_metrics VALUES
              ('2026-09-25 12:00:00',10,30,28,0.4,0.02,0.5,'paste_event_sent','measured',1);
        """)
    before = read(path)
    names = ["hotkey_to_capture_ready_seconds", "capture_stop_seconds",
             "destination_capture_seconds", "remaining_drain_wait_seconds",
             "inference_lease_wait_seconds", "engine_transcription_seconds",
             "raw_history_write_seconds", "pre_delivery_history_seconds",
             "paste_validation_seconds", "stop_to_paste_event_seconds"]
    labels = ["insertion_failure_kind", "insertion_tier", "capture_outcome",
              "cleanup_fallback_reason", "build_label", "foreground_bundle_identifier"]
    with sqlite3.connect(path) as connection:
        for name in names:
            connection.execute(f'ALTER TABLE dictation_metrics ADD COLUMN "{name}" REAL')
        for name in labels:
            connection.execute(f'ALTER TABLE dictation_metrics ADD COLUMN "{name}" TEXT')
        connection.execute("UPDATE dictation_metrics SET schema_version=2, build_label='synthetic/test', stop_to_paste_event_seconds=0.45")
    after = read(path)
    assert before == after, "Existing consumer selection changed"
    assert not set(names + labels) & set(after[0]), "Consumer must keep its allowlist"
    assert reader.summarize_dictations(before[2], 40) == reader.summarize_dictations(after[2], 40)
print("Home Base selector and savings compatibility passed (synthetic fixture only).")
