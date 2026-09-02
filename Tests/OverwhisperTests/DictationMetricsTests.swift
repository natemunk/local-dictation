import Foundation
import GRDB
import Testing
@testable import LocalDictation

@Suite("Transcript-free dictation metrics")
struct DictationMetricsTests {
    @Test("fresh databases expose only the canonical transcript-free schema")
    func freshSchema() async throws {
        let store = try HistoryStore.inMemory()

        #expect(Set(try await store.metricsDatabaseColumnNames()) == Set([
            "event_id",
            "completed_at",
            "recording_duration_seconds",
            "raw_word_count",
            "delivered_word_count",
            "dictation_mode",
            "speech_engine",
            "speech_model",
            "cleanup_backend",
            "cleanup_outcome",
            "asr_latency_seconds",
            "cleanup_latency_seconds",
            "stop_to_delivery_latency_seconds",
            "delivery_outcome",
            "recognized_command_count",
            "words_removed",
            "destination_bundle_identifier",
            "destination_display_name",
            "source_kind",
            "timing_complete",
            "created_at",
            "updated_at",
            "event_revision",
            "schema_version",
        ]))
        #expect(try await store.metricsForeignKeyCount() == 0)
        #expect(try await store.metricCount() == 0)

        let forbiddenFragments = [
            "transcript", "audio", "url", "window", "title", "content", "error",
        ]
        #expect(
            try await store.metricsDatabaseColumnNames().allSatisfy { column in
                forbiddenFragments.allSatisfy {
                    !column.localizedCaseInsensitiveContains($0)
                }
            }
        )
    }

    @Test("existing history is preserved and honestly backfilled exactly once")
    func legacyBackfill() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let id = UUID()
        let completedAt = Date(timeIntervalSinceReferenceDate: 10_000)

        do {
            let legacyDatabase = try DatabaseQueue(path: databaseURL.path)
            try HistoryStore.makeMigrator().migrate(
                legacyDatabase,
                upTo: HistoryStore.metadataMigrationIdentifier
            )
            try await legacyDatabase.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO dictation_history (
                            id, timestamp, raw_text, polished_text,
                            destination_bundle_identifier, destination_display_name,
                            mode, delivery_status, refinement_status, asr_latency,
                            refinement_latency, total_latency,
                            unrecognized_command_candidates_json, error,
                            polish_retry_count, last_polish_attempt_at,
                            asr_selection, asr_outcome, refiner_backend,
                            refinement_outcome, validation_failure_kind,
                            stop_to_paste_latency
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        id.uuidString.lowercased(),
                        completedAt,
                        "alpha beta gamma delta",
                        "alpha gamma delta",
                        "com.example.Editor",
                        "Editor",
                        HistoryDictationMode.clean.rawValue,
                        HistoryDeliveryStatus.previewed.rawValue,
                        HistoryRefinementStatus.succeeded.rawValue,
                        0.4,
                        0.2,
                        4.0,
                        "[]",
                        nil,
                        0,
                        nil,
                        "parakeetV2",
                        "final",
                        "deterministic",
                        "deterministic",
                        nil,
                        0.7,
                    ]
                )
            }
        }

        let store = try HistoryStore(databaseURL: databaseURL)
        let history = try #require(try await store.fetch(id: id))
        let metric = try #require(try await store.fetchMetric(eventID: id))

        #expect(history.id == id)
        #expect(metric.eventID == id)
        #expect(metric.completedAt == completedAt)
        #expect(metric.rawWordCount == 4)
        #expect(metric.deliveredWordCount == 3)
        #expect(metric.wordsRemoved == 1)
        #expect(metric.dictationMode == "clean")
        #expect(metric.deliveryOutcome == "previewed")
        #expect(metric.cleanupOutcome == "deterministic")
        #expect(metric.cleanupLatencySeconds == 0.2)
        #expect(metric.stopToDeliveryLatencySeconds == 0.7)
        #expect(metric.recordingDurationSeconds == nil)
        #expect(metric.asrLatencySeconds == nil)
        #expect(metric.speechEngine == nil)
        #expect(metric.speechModel == nil)
        #expect(metric.cleanupBackend == nil)
        #expect(metric.recognizedCommandCount == nil)
        #expect(metric.sourceKind == .legacyHistory)
        #expect(!metric.timingComplete)
        #expect(try await store.metricCount(sourceKind: .legacyHistory) == 1)
        #expect(try await store.backfillLegacyMetrics() == 0)
        #expect(try await store.metricCount() == 1)
        #expect(try await store.fetch(id: id)?.id == id)
    }

    @Test("each attempt has one row and newer delivery revisions win")
    func oneRowPerAttemptAndLateUpdates() async throws {
        let store = try HistoryStore.inMemory()
        let id = UUID()

        #expect(try await store.upsertMetric(metric(id: id, outcome: "previewed", revision: 1)))
        #expect(!(try await store.upsertMetric(metric(id: id, outcome: "failed", revision: 1))))
        #expect(try await store.upsertMetric(metric(id: id, outcome: "delivered", revision: 2)))
        #expect(!(try await store.upsertMetric(metric(id: id, outcome: "previewed", revision: 1))))

        #expect(try await store.metricCount() == 1)
        let final = try #require(try await store.fetchMetric(eventID: id))
        #expect(final.deliveryOutcome == "delivered")
        #expect(final.eventRevision == 2)
    }

    @Test("stable terminal outcome values round-trip")
    func outcomes() async throws {
        let store = try HistoryStore.inMemory()
        let outcomes = [
            "delivered",
            "previewed",
            "pasted_raw",
            "paste_event_sent",
            "clipboard_only",
            "history_only",
            "failed",
            "cancelled",
        ]

        for outcome in outcomes {
            let id = UUID()
            _ = try await store.upsertMetric(metric(id: id, outcome: outcome, revision: 1))
            #expect(try await store.fetchMetric(eventID: id)?.deliveryOutcome == outcome)
        }
        #expect(try await store.metricCount() == outcomes.count)
    }

    @Test("uptime timing uses the canonical lifecycle boundaries")
    func monotonicTiming() {
        var timing = DictationMetricTiming(recordingStartedAtUptime: 100)
        timing.markRecordingStopped(at: 106)
        timing.markASRCompleted(at: 108.5)
        timing.markCleanupStarted(at: 109)
        timing.markCleanupCompleted(at: 110.25)

        #expect(timing.recordingDurationSeconds == 6)
        #expect(timing.asrLatencySeconds == 2.5)
        #expect(timing.cleanupLatencySeconds == 1.25)
        #expect(timing.stopToDeliveryLatencySeconds(completedAtUptime: 111) == 5)

        timing.markRecordingStopped(at: 999)
        timing.markASRCompleted(at: 999)
        #expect(timing.recordingDurationSeconds == 6)
        #expect(timing.asrLatencySeconds == 2.5)
    }

    @Test("recording duration remains unavailable until capture actually starts")
    func captureStartIsExplicit() {
        var timing = DictationMetricTiming()
        timing.markRecordingStopped(at: 106)
        #expect(timing.recordingDurationSeconds == nil)
        #expect(timing.stopToDeliveryLatencySeconds(completedAtUptime: 108) == 2)

        var measured = DictationMetricTiming()
        measured.markRecordingStarted(at: 100)
        measured.markRecordingStarted(at: 101)
        measured.markRecordingStopped(at: 106)
        #expect(measured.recordingDurationSeconds == 6)
    }

    @Test("analytics disabled performs no write")
    func analyticsDisabled() async throws {
        let store = try HistoryStore.inMemory()
        let wrote = try await store.upsertMetric(
            metric(id: UUID(), outcome: "delivered", revision: 1),
            analyticsEnabled: false
        )
        #expect(!wrote)
        #expect(try await store.metricCount() == 0)
    }

    @Test("destination analytics disabled redacts both app fields")
    func destinationAnalyticsDisabled() {
        let disabled = DictationMetricDestinationMetadata(
            bundleIdentifier: "com.example.Editor",
            displayName: "Editor",
            analyticsEnabled: false
        )
        #expect(disabled.bundleIdentifier == nil)
        #expect(disabled.displayName == nil)

        let enabled = DictationMetricDestinationMetadata(
            bundleIdentifier: "com.example.Editor",
            displayName: "Editor",
            analyticsEnabled: true
        )
        #expect(enabled.bundleIdentifier == "com.example.Editor")
        #expect(enabled.displayName == "Editor")
    }

    @Test("transcript retention and analytics reset are independent")
    func independentDeletionAndRetention() async throws {
        let store = try HistoryStore.inMemory()
        let oldDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let now = oldDate.addingTimeInterval(200 * 24 * 60 * 60)
        let history = try await store.saveRaw(
            HistoryRawCapture(
                timestamp: oldDate,
                rawText: "synthetic retained metric source",
                mode: .literal
            )
        )
        _ = try await store.upsertMetric(
            metric(id: history.id, outcome: "delivered", revision: 1)
        )

        #expect(try await store.pruneEntries(relativeTo: now) == 1)
        #expect(try await store.fetch(id: history.id) == nil)
        #expect(try await store.fetchMetric(eventID: history.id) != nil)

        let second = try await store.saveRaw(
            HistoryRawCapture(rawText: "second synthetic row", mode: .literal)
        )
        _ = try await store.upsertMetric(
            metric(id: second.id, outcome: "previewed", revision: 1)
        )
        #expect(try await store.resetAnalytics() == 2)
        #expect(try await store.metricCount() == 0)
        #expect(try await store.fetch(id: second.id) != nil)

        _ = try await store.upsertMetric(
            metric(id: second.id, outcome: "previewed", revision: 2)
        )
        #expect(try await store.deleteTranscriptHistory() == 1)
        #expect(try await store.fetchRecent().isEmpty)
        #expect(try await store.metricCount() == 1)

        let deleted = try await store.deleteEverything()
        #expect(deleted.history == 0)
        #expect(deleted.metrics == 1)
        #expect(try await store.metricCount() == 0)
    }

    @Test("delete everything checkpoints and scrubs persisted text")
    func deleteEverythingScrubsPersistentFiles() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let store = try HistoryStore(databaseURL: databaseURL)
        let marker = "private-marker-\(UUID().uuidString)"
        let history = try await store.saveRaw(
            HistoryRawCapture(rawText: marker, mode: .literal)
        )
        _ = try await store.upsertMetric(
            DictationMetricEvent(
                eventID: history.id,
                completedAt: Date(),
                recordingDurationSeconds: 1,
                rawWordCount: 1,
                deliveredWordCount: 1,
                dictationMode: "literal",
                speechEngine: "fluidaudio",
                speechModel: "parakeet-v2",
                cleanupBackend: "none",
                cleanupOutcome: "not_requested",
                asrLatencySeconds: 0.1,
                cleanupLatencySeconds: nil,
                stopToDeliveryLatencySeconds: 0.2,
                deliveryOutcome: "paste_event_sent",
                recognizedCommandCount: 0,
                wordsRemoved: 0,
                destinationBundleIdentifier: marker,
                destinationDisplayName: marker,
                sourceKind: .measured,
                timingComplete: true,
                eventRevision: 1,
                schemaVersion: DictationMetricEvent.currentSchemaVersion
            )
        )

        // Home Base may keep an idle read-only connection open while the user
        // clears Local Dictation data. That connection must not prevent the
        // checkpoint/vacuum path from completing.
        var readerConfiguration = Configuration()
        readerConfiguration.readonly = true
        let reader = try DatabaseQueue(
            path: databaseURL.path,
            configuration: readerConfiguration
        )
        try await reader.read { db in
            _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dictation_metrics")
        }

        #expect(try persistedDatabaseFiles(databaseURL).contains(marker: marker))
        let deleted = try await store.deleteEverything()
        #expect(deleted.history == 1)
        #expect(deleted.metrics == 1)
        #expect(!(try persistedDatabaseFiles(databaseURL).contains(marker: marker)))
    }

    @Test("read-only SQLite clients remain available during metric writes")
    func concurrentReadOnlyAccess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let store = try HistoryStore(databaseURL: databaseURL)

        var configuration = Configuration()
        configuration.readonly = true
        let reader = try DatabaseQueue(path: databaseURL.path, configuration: configuration)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for revision in 1...40 {
                    _ = try await store.upsertMetric(
                        metric(
                            id: UUID(),
                            outcome: revision.isMultiple(of: 2) ? "delivered" : "previewed",
                            revision: 1
                        )
                    )
                }
            }
            group.addTask {
                for _ in 0..<40 {
                    try reader.read { db in
                        _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dictation_metrics")
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(try await store.metricCount() == 40)
    }

    private func metric(
        id: UUID,
        outcome: String,
        revision: Int64
    ) -> DictationMetricEvent {
        DictationMetricEvent(
            eventID: id,
            completedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(revision)),
            recordingDurationSeconds: 2,
            rawWordCount: 4,
            deliveredWordCount: ["failed", "cancelled"].contains(outcome) ? 0 : 3,
            dictationMode: "clean",
            speechEngine: "fluidaudio",
            speechModel: "parakeet-v2",
            cleanupBackend: "deterministic",
            cleanupOutcome: "deterministic",
            asrLatencySeconds: 0.4,
            cleanupLatencySeconds: 0.1,
            stopToDeliveryLatencySeconds: 0.6,
            deliveryOutcome: outcome,
            recognizedCommandCount: 1,
            wordsRemoved: 1,
            destinationBundleIdentifier: "com.example.Editor",
            destinationDisplayName: "Editor",
            sourceKind: .measured,
            timingComplete: true,
            eventRevision: revision,
            schemaVersion: DictationMetricEvent.currentSchemaVersion
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-metrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func persistedDatabaseFiles(_ databaseURL: URL) throws -> Data {
        var combined = Data()
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where FileManager.default.fileExists(atPath: url.path) {
            combined.append(try Data(contentsOf: url))
        }
        return combined
    }
}

private extension Data {
    func contains(marker: String) -> Bool {
        range(of: Data(marker.utf8)) != nil
    }
}
