import Foundation
import Testing
@testable import LocalDictation

@Suite("Dictation history store")
struct HistoryStoreTests {
    @Test("migrations are durable and idempotent")
    func migrations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let id = UUID()

        do {
            let store = try HistoryStore(databaseURL: databaseURL)
            _ = try store.saveRaw(
                HistoryRawCapture(id: id, rawText: "survives reopening", mode: .literal)
            )
            #expect(
                try store.appliedMigrationIdentifiers() == [
                    HistoryStore.schemaMigrationIdentifier,
                    HistoryStore.searchMigrationIdentifier,
                ]
            )
        }

        let reopened = try HistoryStore(databaseURL: databaseURL)
        #expect(try reopened.fetch(id: id)?.rawText == "survives reopening")
        #expect(
            try reopened.appliedMigrationIdentifiers() == [
                HistoryStore.schemaMigrationIdentifier,
                HistoryStore.searchMigrationIdentifier,
            ]
        )

        let objects = try reopened.databaseSchemaObjectNames()
        #expect(objects.contains("dictation_history"))
        #expect(objects.contains("dictation_history_fts"))
        #expect(objects.contains { $0.contains("dictation_history_fts") && $0.contains("ai") })
        #expect(objects.contains { $0.contains("dictation_history_fts") && $0.contains("au") })
        #expect(objects.contains { $0.contains("dictation_history_fts") && $0.contains("ad") })
    }

    @Test("raw transcript survives polish failure and is returned for retry")
    func rawSurvivesFailureAndRetry() throws {
        let store = try HistoryStore.inMemory()
        let id = UUID()
        let failedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let retryAt = Date(timeIntervalSinceReferenceDate: 2_000)

        let saved = try store.saveRaw(
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

        let failed = try store.markPolishFailed(
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
        #expect(try store.text(for: id, version: .raw) == failed.rawText)
        #expect(try store.text(for: id, version: .polished) == nil)
        #expect(try store.text(for: id, version: .delivered) == failed.rawText)

        let retry = try store.beginPolishRetry(id: id, at: retryAt)
        #expect(retry.rawText == failed.rawText)
        #expect(retry.retryCount == 1)
        #expect(retry.startedAt == retryAt)

        let retrying = try #require(try store.fetch(id: id))
        #expect(retrying.rawText == failed.rawText)
        #expect(retrying.refinementStatus == .retrying)
        #expect(retrying.deliveryStatus == .pending)
        #expect(retrying.polishRetryCount == 1)
        #expect(retrying.lastPolishAttemptAt == retryAt)
        #expect(retrying.error == nil)
    }

    @Test("successful raw fallback follows the 90-day delivery retention policy")
    func pastedRawFallback() throws {
        let store = try HistoryStore.inMemory()
        let day: TimeInterval = 24 * 60 * 60
        let now = Date(timeIntervalSinceReferenceDate: 20_000_000)
        let recentSaved = try store.saveRaw(
            HistoryRawCapture(
                timestamp: now.addingTimeInterval(-30 * day),
                rawText: "fallback preserves these exact words",
                mode: .clean
            )
        )

        let recentFallback = try store.markPolishFailed(
            id: recentSaved.id,
            error: "polish validation timed out",
            deliveryStatus: .pastedRaw,
            totalLatency: 1.5,
            at: now
        )

        #expect(HistoryRetentionPolicy.default.successRetentionDays == 90)
        #expect(HistoryDeliveryStatus.pastedRaw.rawValue == "pasted_raw")
        #expect(HistoryDeliveryStatus.pastedRaw.isSuccessful)
        #expect(recentFallback.deliveryStatus == .pastedRaw)
        #expect(recentFallback.refinementStatus == .failed)
        #expect(recentFallback.polishedText == nil)
        #expect(recentFallback.deliveredText == recentFallback.rawText)

        #expect(try store.pruneSuccessfulEntries(relativeTo: now) == 0)
        #expect(try store.fetch(id: recentSaved.id) != nil)

        _ = try store.beginPolishRetry(id: recentSaved.id, at: now.addingTimeInterval(1))
        let retrying = try #require(try store.fetch(id: recentSaved.id))
        #expect(retrying.refinementStatus == .retrying)
        #expect(retrying.deliveryStatus == .pastedRaw)
        #expect(retrying.deliveredText == retrying.rawText)
        #expect(try store.pruneSuccessfulEntries(relativeTo: now) == 0)

        let oldSaved = try store.saveRaw(
            HistoryRawCapture(
                timestamp: now.addingTimeInterval(-91 * day),
                rawText: "old fallback was still delivered",
                mode: .clean
            )
        )
        let oldFallback = try store.markPolishFailed(
            id: oldSaved.id,
            error: "polish validation timed out",
            deliveryStatus: .pastedRaw,
            at: now
        )
        #expect(oldFallback.refinementStatus == .failed)
        #expect(oldFallback.deliveryStatus == .pastedRaw)

        #expect(try store.pruneSuccessfulEntries(relativeTo: now) == 1)
        #expect(try store.fetch(id: oldSaved.id) == nil)
        #expect(try store.fetch(id: recentSaved.id) != nil)
    }

    @Test("honest insertion outcomes round-trip without claiming confirmed delivery")
    func insertionOutcomeStatuses() throws {
        let store = try HistoryStore.inMemory()
        let sent = try saveEntry(
            in: store,
            timestamp: Date(),
            rawText: "paste event only",
            refinementStatus: .notRequested,
            deliveryStatus: .pasteEventSent
        )
        let clipboard = try saveEntry(
            in: store,
            timestamp: Date(),
            rawText: "clipboard recovery",
            refinementStatus: .notRequested,
            deliveryStatus: .clipboardOnly
        )
        let history = try saveEntry(
            in: store,
            timestamp: Date(),
            rawText: "history recovery",
            refinementStatus: .notRequested,
            deliveryStatus: .historyOnly
        )

        #expect(try store.fetch(id: sent.id)?.deliveryStatus == .pasteEventSent)
        #expect(try store.fetch(id: clipboard.id)?.deliveryStatus == .clipboardOnly)
        #expect(try store.fetch(id: history.id)?.deliveryStatus == .historyOnly)
        #expect(HistoryDeliveryStatus.pasteEventSent.isSuccessful)
        #expect(HistoryDeliveryStatus.clipboardOnly.isSuccessful)
        #expect(!HistoryDeliveryStatus.historyOnly.isSuccessful)
    }

    @Test("FTS5 searches raw and polished text and follows updates")
    func fullTextSearch() throws {
        let store = try HistoryStore.inMemory()
        let targetID = UUID()

        _ = try store.saveRaw(
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
        _ = try store.saveRaw(
            HistoryRawCapture(rawText: "an unrelated grocery reminder", mode: .literal)
        )

        _ = try store.finalize(
            id: targetID,
            with: HistoryFinalization(
                polishedText: "The polished cobalt sentence.",
                refinementStatus: .succeeded,
                deliveryStatus: .delivered,
                refinementLatency: 0.2,
                totalLatency: 0.7
            )
        )

        #expect(try store.search("nebula").map(\.id) == [targetID])
        #expect(try store.search("polished cobalt").map(\.id) == [targetID])
        #expect(try store.search("Notes").map(\.id) == [targetID])
        #expect(try store.search("AND").isEmpty)
        #expect(try store.search("   ").isEmpty)
    }

    @Test("retention prunes old successes and preserves non-successful deliveries")
    func retention() throws {
        let store = try HistoryStore.inMemory()
        let day: TimeInterval = 24 * 60 * 60
        let now = Date(timeIntervalSinceReferenceDate: 20_000_000)

        let oldSuccess = try saveEntry(
            in: store,
            timestamp: now.addingTimeInterval(-91 * day),
            rawText: "old success",
            refinementStatus: .notRequested,
            deliveryStatus: .delivered
        )
        let oldPolishFailure = try store.saveRaw(
            HistoryRawCapture(
                timestamp: now.addingTimeInterval(-200 * day),
                rawText: "old polish failure",
                mode: .clean
            )
        )
        _ = try store.markPolishFailed(id: oldPolishFailure.id, error: "polish failed")

        let oldDeliveryFailure = try saveEntry(
            in: store,
            timestamp: now.addingTimeInterval(-200 * day),
            rawText: "old delivery failure",
            refinementStatus: .succeeded,
            deliveryStatus: .failed,
            error: "paste failed"
        )
        let oldCancelled = try saveEntry(
            in: store,
            timestamp: now.addingTimeInterval(-200 * day),
            rawText: "old cancelled delivery",
            refinementStatus: .notRequested,
            deliveryStatus: .cancelled
        )
        let oldPending = try store.saveRaw(
            HistoryRawCapture(
                timestamp: now.addingTimeInterval(-200 * day),
                rawText: "old recoverable pending delivery",
                mode: .clean
            )
        )
        let recentSuccess = try saveEntry(
            in: store,
            timestamp: now.addingTimeInterval(-31 * day),
            rawText: "recent success",
            refinementStatus: .notRequested,
            deliveryStatus: .previewed
        )

        #expect(try store.pruneSuccessfulEntries(relativeTo: now) == 1)
        #expect(try store.fetch(id: oldSuccess.id) == nil)
        #expect(try store.fetch(id: oldPolishFailure.id) != nil)
        #expect(try store.fetch(id: oldDeliveryFailure.id) != nil)
        #expect(try store.fetch(id: oldCancelled.id) != nil)
        #expect(try store.fetch(id: oldPending.id) != nil)
        #expect(try store.fetch(id: recentSuccess.id) != nil)

        #expect(
            try store.pruneSuccessfulEntries(
                policy: HistoryRetentionPolicy(successRetentionDays: 30),
                relativeTo: now
            ) == 1
        )
        #expect(try store.fetch(id: recentSuccess.id) == nil)
        #expect(try store.fetch(id: oldPolishFailure.id) != nil)
        #expect(try store.fetch(id: oldDeliveryFailure.id) != nil)
        #expect(try store.fetch(id: oldCancelled.id) != nil)
        #expect(try store.fetch(id: oldPending.id) != nil)
    }

    @Test("individual and bulk deletion also remove FTS results")
    func deletion() throws {
        let store = try HistoryStore.inMemory()
        let first = try store.saveRaw(
            HistoryRawCapture(rawText: "delete zircon transcript", mode: .literal)
        )
        let second = try store.saveRaw(
            HistoryRawCapture(rawText: "keep amber transcript", mode: .literal)
        )

        #expect(try store.delete(id: first.id))
        #expect(try !store.delete(id: first.id))
        #expect(try store.fetch(id: first.id) == nil)
        #expect(try store.search("zircon").isEmpty)
        #expect(try store.fetch(id: second.id) != nil)

        #expect(try store.deleteAll() == 1)
        #expect(try store.fetchRecent().isEmpty)
        #expect(try store.search("amber").isEmpty)
    }

    @Test("schema and destination model contain no browser or page field")
    func destinationPrivacyBoundary() throws {
        let store = try HistoryStore.inMemory()
        let columns = try store.databaseColumnNames()
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

    @Test("concurrent callers safely serialize writes")
    func concurrentWrites() async throws {
        let store = try HistoryStore.inMemory()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    _ = try store.saveRaw(
                        HistoryRawCapture(
                            rawText: "concurrent transcript \(index)",
                            mode: .literal
                        )
                    )
                }
            }
            try await group.waitForAll()
        }

        #expect(try store.fetchRecent(limit: 100).count == 24)
    }

    private func saveEntry(
        in store: HistoryStore,
        timestamp: Date,
        rawText: String,
        refinementStatus: HistoryRefinementStatus,
        deliveryStatus: HistoryDeliveryStatus,
        error: String? = nil
    ) throws -> HistoryEntry {
        let raw = try store.saveRaw(
            HistoryRawCapture(
                timestamp: timestamp,
                rawText: rawText,
                mode: refinementStatus == .notRequested ? .literal : .clean
            )
        )
        return try store.finalize(
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
