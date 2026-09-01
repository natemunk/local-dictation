import Foundation
import GRDB
import Testing
@testable import LocalDictation

@Suite("Dictation history store")
struct HistoryStoreTests {
    @Test("file-backed stores use WAL and expose privacy-safe health diagnostics")
    func walAndHealthDiagnostics() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let store = try HistoryStore(databaseURL: databaseURL)
        let entry = try await store.saveRaw(
            HistoryRawCapture(rawText: "health does not expose this transcript", mode: .literal)
        )
        let health = try await store.health(
            policy: HistoryRetentionPolicy(retentionDays: 30)
        )

        #expect(health.journalMode == "wal")
        #expect(health.appliedMigrationIdentifiers == [
            HistoryStore.schemaMigrationIdentifier,
            HistoryStore.searchMigrationIdentifier,
            HistoryStore.searchBundleMigrationIdentifier,
            HistoryStore.metadataMigrationIdentifier,
        ])
        #expect(health.retentionPolicy == HistoryRetentionPolicy(retentionDays: 30))
        #expect(health.retentionDays == 30)
        #expect(health.entryCount == 1)
        #expect(try await store.fetch(id: entry.id) != nil)
    }

    @Test("migrations are durable, backward-compatible, and idempotent")
    func migrations() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let legacyID = UUID()
        let legacyTimestamp = Date(timeIntervalSinceReferenceDate: 1_000)

        do {
            let legacyDatabase = try DatabaseQueue(path: databaseURL.path)
            try HistoryStore.makeMigrator().migrate(
                legacyDatabase,
                upTo: HistoryStore.schemaMigrationIdentifier
            )
            try await legacyDatabase.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO dictation_history (
                            id, timestamp, raw_text, destination_bundle_identifier,
                            destination_display_name, mode, delivery_status,
                            refinement_status, asr_latency,
                            unrecognized_command_candidates_json, error,
                            polish_retry_count, last_polish_attempt_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        legacyID.uuidString.lowercased(),
                        legacyTimestamp,
                        "legacy transcript",
                        "com.example.LegacyEditor",
                        "Legacy Editor",
                        HistoryDictationMode.literal.rawValue,
                        HistoryDeliveryStatus.pending.rawValue,
                        HistoryRefinementStatus.notRequested.rawValue,
                        nil,
                        "[]",
                        nil,
                        0,
                        nil,
                    ]
                )
            }
        }

        let store = try HistoryStore(databaseURL: databaseURL)
        let legacy = try #require(try await store.fetch(id: legacyID))
        #expect(legacy.rawText == "legacy transcript")
        #expect(legacy.timestamp == legacyTimestamp)
        #expect(legacy.asrSelection == nil)
        #expect(legacy.asrOutcome == nil)
        #expect(legacy.refinerBackend == nil)
        #expect(legacy.refinementOutcome == nil)
        #expect(legacy.validationFailureKind == nil)
        #expect(legacy.stopToPasteLatency == nil)
        #expect(try await store.appliedMigrationIdentifiers() == [
            HistoryStore.schemaMigrationIdentifier,
            HistoryStore.searchMigrationIdentifier,
            HistoryStore.searchBundleMigrationIdentifier,
            HistoryStore.metadataMigrationIdentifier,
        ])

        let reopened = try HistoryStore(databaseURL: databaseURL)
        #expect(try await reopened.fetch(id: legacyID)?.rawText == "legacy transcript")
        #expect(try await reopened.appliedMigrationIdentifiers() == [
            HistoryStore.schemaMigrationIdentifier,
            HistoryStore.searchMigrationIdentifier,
            HistoryStore.searchBundleMigrationIdentifier,
            HistoryStore.metadataMigrationIdentifier,
        ])
        #expect(try await reopened.health().entryCount == 1)
    }

    @Test("raw transcript survives polish failure and is returned for retry")
    func rawSurvivesFailureAndRetry() async throws {
        let store = try HistoryStore.inMemory()
        let id = UUID()
        let failedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let retryAt = Date(timeIntervalSinceReferenceDate: 2_000)

        let saved = try await store.saveRaw(
            HistoryRawCapture(
                id: id,
                timestamp: Date(timeIntervalSinceReferenceDate: 900),
                rawText: "raw words actually keep this version",
                destination: HistoryDestination(
                    bundleIdentifier: "com.apple.TextEdit",
                    displayName: "TextEdit"
                ),
                mode: .clean,
                asrLatency: 0.42,
                unrecognizedCommandCandidates: ["new paragraph", "literal comma"]
            )
        )
        #expect(saved.refinementStatus == .pending)

        let failed = try await store.markPolishFailed(
            id: id,
            error: "local model unavailable",
            refinementLatency: 0.18,
            totalLatency: 0.60,
            at: failedAt
        )

        #expect(failed.rawText == "raw words actually keep this version")
        #expect(failed.polishedText == nil)
        #expect(failed.refinementStatus == .failed)
        #expect(failed.deliveryStatus == .failed)
        #expect(failed.error == "local model unavailable")
        #expect(failed.unrecognizedCommandCandidates == ["new paragraph", "literal comma"])
        #expect(try await store.text(for: id, version: .raw) == failed.rawText)
        #expect(try await store.text(for: id, version: .polished) == nil)
        #expect(try await store.text(for: id, version: .delivered) == failed.rawText)

        let retry = try await store.beginPolishRetry(id: id, at: retryAt)
        #expect(retry.rawText == failed.rawText)
        #expect(retry.retryCount == 1)
        #expect(retry.startedAt == retryAt)

        let retrying = try #require(try await store.fetch(id: id))
        #expect(retrying.rawText == failed.rawText)
        #expect(retrying.refinementStatus == .retrying)
        #expect(retrying.deliveryStatus == .pending)
        #expect(retrying.polishRetryCount == 1)
        #expect(retrying.lastPolishAttemptAt == retryAt)
        #expect(retrying.error == nil)
    }

    @Test("new processing metadata round-trips without changing raw text")
    func processingMetadataRoundTrip() async throws {
        let store = try HistoryStore.inMemory()
        let id = UUID()
        let rawText = "immutable ASR transcript"

        _ = try await store.saveRaw(
            HistoryRawCapture(
                id: id,
                rawText: rawText,
                mode: .clean,
                asrSelection: "parakeet_v2",
                asrOutcome: "final"
            )
        )
        let finalized = try await store.finalize(
            id: id,
            with: HistoryFinalization(
                polishedText: "polished transcript",
                refinementStatus: .failed,
                deliveryStatus: .pastedRaw,
                refinementLatency: 0.20,
                totalLatency: 0.70,
                error: "validator rejected output",
                refinerBackend: "apple_foundation",
                refinementOutcome: "deterministic_fallback",
                validationFailureKind: "lexical_addition",
                stopToPasteLatency: 0.12
            )
        )

        #expect(finalized.rawText == rawText)
        #expect(finalized.asrSelection == "parakeet_v2")
        #expect(finalized.asrOutcome == "final")
        #expect(finalized.refinerBackend == "apple_foundation")
        #expect(finalized.refinementOutcome == "deterministic_fallback")
        #expect(finalized.validationFailureKind == "lexical_addition")
        #expect(finalized.stopToPasteLatency == 0.12)

        let updated = try await store.updateDelivery(
            id: id,
            with: HistoryDeliveryUpdate(
                status: .pastedRaw,
                stopToPasteLatency: 0.18
            )
        )
        #expect(updated.rawText == rawText)
        #expect(updated.stopToPasteLatency == 0.18)
        #expect(try await store.text(for: id, version: .raw) == rawText)
    }

    @Test("retention prunes every entry state using the default and custom policies")
    func retention() async throws {
        let store = try HistoryStore.inMemory()
        let day: TimeInterval = 24 * 60 * 60
        let now = Date(timeIntervalSinceReferenceDate: 20_000_000)

        let oldPending = try await store.saveRaw(
            HistoryRawCapture(
                timestamp: now.addingTimeInterval(-200 * day),
                rawText: "old pending",
                mode: .literal
            )
        )
        let oldEntries = try await makeEntries(
            in: store,
            now: now,
            statuses: [
                .delivered,
                .previewed,
                .pastedRaw,
                .pasteEventSent,
                .clipboardOnly,
                .historyOnly,
                .failed,
                .cancelled,
            ]
        )
        let recent = try await saveEntry(
            in: store,
            timestamp: now.addingTimeInterval(-31 * day),
            rawText: "recent entry",
            refinementStatus: .notRequested,
            deliveryStatus: .previewed
        )

        #expect(HistoryRetentionPolicy.default.retentionDays == 90)
        #expect(HistoryRetentionPolicy.default.successRetentionDays == 90)
        #expect(try await store.pruneEntries(relativeTo: now) == oldEntries.count + 1)
        #expect(try await store.fetch(id: oldPending.id) == nil)
        for entry in oldEntries {
            #expect(try await store.fetch(id: entry.id) == nil)
        }

        #expect(
            try await store.pruneEntries(
                policy: HistoryRetentionPolicy(retentionDays: 30),
                relativeTo: now
            ) == 1
        )
        #expect(try await store.fetch(id: recent.id) == nil)

        let compatibilityEntry = try await saveEntry(
            in: store,
            timestamp: now.addingTimeInterval(-200 * day),
            rawText: "compatibility prune",
            refinementStatus: .notRequested,
            deliveryStatus: .failed
        )
        #expect(try await store.pruneSuccessfulEntries(relativeTo: now) == 1)
        #expect(try await store.fetch(id: compatibilityEntry.id) == nil)
    }

    @Test("FTS searches ordinary tokens across text and destination metadata")
    func fullTextSearch() async throws {
        let store = try HistoryStore.inMemory()
        let targetID = UUID()

        _ = try await store.saveRaw(
            HistoryRawCapture(
                id: targetID,
                rawText: "the unedited nebula transcript",
                destination: HistoryDestination(
                    bundleIdentifier: "com.apple.Notes",
                    displayName: "Notes"
                ),
                mode: .clean
            )
        )
        _ = try await store.saveRaw(
            HistoryRawCapture(rawText: "an unrelated grocery reminder", mode: .literal)
        )

        _ = try await store.finalize(
            id: targetID,
            with: HistoryFinalization(
                polishedText: "The polished cobalt sentence.",
                refinementStatus: .succeeded,
                deliveryStatus: .delivered,
                refinementLatency: 0.2,
                totalLatency: 0.7
            )
        )

        #expect(try await store.search("nebula").map(\.id) == [targetID])
        #expect(try await store.search("polished cobalt").map(\.id) == [targetID])
        #expect(try await store.search("Notes").map(\.id) == [targetID])
        #expect(try await store.search("AND").isEmpty)
        #expect(try await store.search("   ").isEmpty)
    }

    @Test("LIKE fallback is escaped, case-insensitive, and searches all text fields")
    func likeFallback() async throws {
        let store = try HistoryStore.inMemory()
        let percent = try await store.saveRaw(
            HistoryRawCapture(
                rawText: "Completion is 100% reliable",
                mode: .literal
            )
        )
        let underscore = try await store.saveRaw(
            HistoryRawCapture(rawText: "snake_case identifier", mode: .literal)
        )
        let quoted = try await store.saveRaw(
            HistoryRawCapture(
                rawText: #"The "quoted" punctuation: works!"#,
                destination: HistoryDestination(
                    bundleIdentifier: "com.example.Writer",
                    displayName: "Writer"
                ),
                mode: .literal
            )
        )
        let polished = try await store.saveRaw(
            HistoryRawCapture(rawText: "fallback source", mode: .literal)
        )
        _ = try await store.finalize(
            id: polished.id,
            with: HistoryFinalization(
                polishedText: "A punctuation-only [result]!",
                refinementStatus: .succeeded,
                deliveryStatus: .delivered
            )
        )

        #expect(try await store.search("%").map(\.id) == [percent.id])
        #expect(try await store.search("_").map(\.id) == [underscore.id])
        #expect(try await store.search("\"quoted\"").map(\.id) == [quoted.id])
        #expect(try await store.search("[result]!").map(\.id) == [polished.id])
        #expect(try await store.search("COM.EXAMPLE.WRITER").map(\.id) == [quoted.id])
        #expect(try await store.search("100%").map(\.id) == [percent.id])
    }

    @Test("individual and bulk deletion also remove FTS results")
    func deletion() async throws {
        let store = try HistoryStore.inMemory()
        let first = try await store.saveRaw(
            HistoryRawCapture(rawText: "delete zircon transcript", mode: .literal)
        )
        let second = try await store.saveRaw(
            HistoryRawCapture(rawText: "keep amber transcript", mode: .literal)
        )

        #expect(try await store.delete(id: first.id))
        #expect(try await !store.delete(id: first.id))
        #expect(try await store.fetch(id: first.id) == nil)
        #expect(try await store.search("zircon").isEmpty)
        #expect(try await store.fetch(id: second.id) != nil)

        #expect(try await store.deleteAll() == 1)
        #expect(try await store.fetchRecent().isEmpty)
        #expect(try await store.search("amber").isEmpty)
    }

    @Test("schema and destination model contain no browser or page field")
    func destinationPrivacyBoundary() async throws {
        let store = try HistoryStore.inMemory()
        let columns = try await store.databaseColumnNames()
        let destinationColumns = Set(columns.filter { $0.hasPrefix("destination_") })

        #expect(
            destinationColumns == [
                "destination_bundle_identifier",
                "destination_display_name",
            ]
        )

        let forbiddenFragments = ["browser", "host", "url", "page", "domain", "title"]
        #expect(
            columns.allSatisfy { column in
                forbiddenFragments.allSatisfy { !column.localizedCaseInsensitiveContains($0) }
            }
        )

        let destinationFields = Set(
            Mirror(
                reflecting: HistoryDestination(
                    bundleIdentifier: "com.apple.Safari",
                    displayName: "Safari"
                )
            ).children.compactMap(\.label)
        )
        #expect(destinationFields == ["bundleIdentifier", "displayName"])
    }

    @Test("actor callers safely serialize concurrent writes")
    func concurrentWrites() async throws {
        let store = try HistoryStore.inMemory()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    _ = try await store.saveRaw(
                        HistoryRawCapture(
                            rawText: "concurrent transcript \(index)",
                            mode: .literal
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        let count = try await Task.detached {
            try await store.fetchRecent(limit: 100).count
        }.value
        #expect(count == 24)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "local-dictation-history-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeEntries(
        in store: HistoryStore,
        now: Date,
        statuses: [HistoryDeliveryStatus]
    ) async throws -> [HistoryEntry] {
        var entries = [HistoryEntry]()
        for (index, status) in statuses.enumerated() {
            entries.append(
                try await saveEntry(
                    in: store,
                    timestamp: now.addingTimeInterval(-200 * 24 * 60 * 60 - TimeInterval(index)),
                    rawText: "old \(status.rawValue)",
                    refinementStatus: status == .failed ? .failed : .notRequested,
                    deliveryStatus: status
                )
            )
        }
        return entries
    }

    private func saveEntry(
        in store: HistoryStore,
        timestamp: Date,
        rawText: String,
        refinementStatus: HistoryRefinementStatus,
        deliveryStatus: HistoryDeliveryStatus,
        error: String? = nil
    ) async throws -> HistoryEntry {
        let raw = try await store.saveRaw(
            HistoryRawCapture(
                timestamp: timestamp,
                rawText: rawText,
                mode: refinementStatus == .notRequested ? .literal : .clean
            )
        )
        return try await store.finalize(
            id: raw.id,
            with: HistoryFinalization(
                polishedText: refinementStatus == .succeeded ? "polished \(rawText)" : nil,
                refinementStatus: refinementStatus,
                deliveryStatus: deliveryStatus,
                error: error
            )
        )
    }
}
