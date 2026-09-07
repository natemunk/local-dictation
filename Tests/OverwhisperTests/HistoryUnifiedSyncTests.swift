import Foundation
import GRDB
import Testing
@testable import LocalDictation

@Suite("Unified history store and sync")
struct HistoryUnifiedSyncTests {
    @Test("unified migration is additive and backfills updated_at")
    func migrationIsAdditive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryUnifiedSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let legacyID = UUID()
        let legacyTimestamp = Date(timeIntervalSinceReferenceDate: 5_000)

        do {
            let legacy = try DatabaseQueue(path: databaseURL.path)
            try HistoryStore.makeMigrator().migrate(legacy, upTo: HistoryStore.metricsMigrationIdentifier)
            try await legacy.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO dictation_history (
                            id, timestamp, raw_text, mode, delivery_status, refinement_status,
                            unrecognized_command_candidates_json, polish_retry_count
                        ) VALUES (?, ?, ?, ?, ?, ?, '[]', 0)
                        """,
                    arguments: [
                        legacyID.uuidString.lowercased(), legacyTimestamp, "legacy words",
                        HistoryDictationMode.clean.rawValue,
                        HistoryDeliveryStatus.delivered.rawValue,
                        HistoryRefinementStatus.succeeded.rawValue,
                    ]
                )
            }
        }

        let store = try HistoryStore(databaseURL: databaseURL)
        let entry = try #require(try await store.fetch(id: legacyID))
        #expect(entry.sourceKind == .desktop)
        #expect(entry.remoteRoute == nil)
        #expect(entry.userEditedText == nil)
        #expect(!entry.isPinned)
        #expect(entry.entryRevision == 1)
        #expect(entry.updatedAt == legacyTimestamp)
        #expect(entry.displayText == "legacy words")
        #expect(try await store.globalRevision() >= 1)
        #expect(try await store.appliedMigrationIdentifiers() == HistoryStore.expectedMigrationIdentifiers)

        let columns = try await store.databaseColumnNames()
        for column in ["source_kind", "remote_route", "cleanup_backend", "user_edited_text", "is_pinned", "entry_revision", "updated_at"] {
            #expect(columns.contains(column))
        }
        // Legacy rows are still searchable after the FTS rebuild.
        #expect(try await store.search("legacy").map(\.id) == [legacyID])
    }

    @Test("remote saves are idempotent on request id and never rewrite text")
    func remoteSaveIdempotent() async throws {
        let store = try HistoryStore.inMemory()
        let id = UUID()
        let revisionBefore = try await store.globalRevision()
        let first = try await store.saveRemote(makeRemote(id: id, raw: "raw one", polished: "Polished one."))
        #expect(first.inserted)
        #expect(first.entry.sourceKind == .iphoneShortcut)
        #expect(first.entry.remoteRoute == "mac_local")
        #expect(first.entry.cleanupBackend == "deterministic")
        #expect(first.entry.deliveryStatus == .delivered)
        #expect(first.entry.deliveryStatus.isSuccessful)
        #expect(first.entry.displayText == "Polished one.")
        #expect(try await store.globalRevision() == revisionBefore + 1)

        let replay = try await store.saveRemote(makeRemote(id: id, raw: "different", polished: "Different."))
        #expect(!replay.inserted)
        #expect(replay.entry.rawText == "raw one")
        #expect(replay.entry.polishedText == "Polished one.")
        #expect(try await store.globalRevision() == revisionBefore + 1)
    }

    @Test("user edits take display precedence, leave raw/polished immutable, and honor revisions")
    func editsAreSeparateAndGuarded() async throws {
        let store = try HistoryStore.inMemory()
        let saved = try await store.saveRaw(HistoryRawCapture(rawText: "raw text", mode: .clean))
        let finalized = try await store.finalize(
            id: saved.id,
            with: HistoryFinalization(polishedText: "Polished text.", refinementStatus: .succeeded, deliveryStatus: .pasteEventSent)
        )
        #expect(finalized.entryRevision == 2)
        #expect(finalized.displayText == "Polished text.")

        let edited = try await store.setUserEditedText(id: saved.id, text: "My edit.", baseRevision: 2)
        #expect(edited.entryRevision == 3)
        #expect(edited.displayText == "My edit.")
        #expect(edited.deliveredText == "Polished text.")
        #expect(edited.rawText == "raw text")
        #expect(edited.polishedText == "Polished text.")
        #expect(edited.updatedAt >= finalized.updatedAt)

        do {
            _ = try await store.setUserEditedText(id: saved.id, text: "stale", baseRevision: 2)
            Issue.record("stale revision should conflict")
        } catch let error as HistoryStoreError {
            #expect(error == .revisionConflict(saved.id, currentRevision: 3))
        }

        let cleared = try await store.setUserEditedText(id: saved.id, text: "   ", baseRevision: 3)
        #expect(cleared.userEditedText == nil)
        #expect(cleared.displayText == "Polished text.")
        #expect(cleared.entryRevision == 4)
    }

    @Test("search matches edited text")
    func searchIncludesEdits() async throws {
        let store = try HistoryStore.inMemory()
        let saved = try await store.saveRaw(HistoryRawCapture(rawText: "alpha beta", mode: .literal))
        _ = try await store.setUserEditedText(id: saved.id, text: "zebra crossing")
        #expect(try await store.search("zebra").map(\.id) == [saved.id])
        #expect(try await store.search("zeb%ra").isEmpty)
        #expect(try await store.search("alpha").map(\.id) == [saved.id])
    }

    @Test("pinned entries survive retention pruning; unpinned ones do not")
    func pinnedRetention() async throws {
        let store = try HistoryStore.inMemory()
        let old = Date(timeIntervalSinceNow: -200 * 24 * 60 * 60)
        let pinned = try await store.saveRaw(HistoryRawCapture(timestamp: old, rawText: "keep me", mode: .literal))
        let unpinned = try await store.saveRaw(HistoryRawCapture(timestamp: old, rawText: "drop me", mode: .literal))
        _ = try await store.setPinned(id: pinned.id, true)

        let before = try await store.globalRevision()
        let pruned = try await store.pruneEntries(policy: HistoryRetentionPolicy(retentionDays: 90))
        #expect(pruned == 1)
        #expect(try await store.fetch(id: pinned.id) != nil)
        #expect(try await store.fetch(id: unpinned.id) == nil)
        #expect(try await store.globalRevision() == before + 1)
        #expect(try await store.pruneEntries(policy: HistoryRetentionPolicy(retentionDays: 90)) == 0)
        #expect(try await store.globalRevision() == before + 1)

        let manifest = try await store.syncManifest(policy: HistoryRetentionPolicy(retentionDays: 90))
        #expect(manifest.entryCount == 1)
        #expect(manifest.pinnedCount == 1)
        #expect(manifest.retention == .standard(unpinnedDays: 90))
    }

    @Test("snapshot pages are consistent and restart when history changes")
    func snapshotPaging() async throws {
        let store = try HistoryStore.inMemory()
        var ids: [UUID] = []
        for index in 0..<5 {
            ids.append(try await store.saveRaw(HistoryRawCapture(rawText: "entry \(index)", mode: .literal)).id)
        }
        let revision = try await store.globalRevision()

        let first = try await store.syncPage(revision: revision, cursor: nil, limit: 2)
        #expect(first.entries.map(\.id) == [ids[4], ids[3]])
        let next = try #require(first.nextCursor)
        let second = try await store.syncPage(revision: revision, cursor: next, limit: 2)
        #expect(second.entries.map(\.id) == [ids[2], ids[1]])
        let third = try await store.syncPage(revision: revision, cursor: second.nextCursor, limit: 2)
        #expect(third.entries.map(\.id) == [ids[0]])
        #expect(third.nextCursor == nil)

        _ = try await store.delete(id: ids[0])
        do {
            _ = try await store.syncPage(revision: revision, cursor: nil, limit: 2)
            Issue.record("expected history_changed")
        } catch let error as HistorySyncError {
            #expect(error == .historyChanged(currentRevision: revision + 1))
        }

        await #expect(throws: HistorySyncError.invalidRequest) {
            _ = try await store.syncPage(revision: revision + 1, cursor: nil, limit: 0)
        }
        await #expect(throws: HistorySyncError.invalidRequest) {
            _ = try await store.syncPage(revision: revision + 1, cursor: "abc", limit: 10)
        }
    }

    @Test("operations are idempotent, independent, and revision-guarded")
    func operations() async throws {
        let store = try HistoryStore.inMemory()
        let desktop = try await store.saveRaw(HistoryRawCapture(rawText: "desktop", mode: .literal))
        let importID = UUID()
        let importOp = UUID()
        let before = try await store.globalRevision()

        let result = try await store.applySyncOperations(HistorySyncOperationBatch(operations: [
            HistorySyncOperation(
                opID: importOp, type: .import, entryID: importID, text: "from the phone",
                createdAt: Date(timeIntervalSinceReferenceDate: 10), sourceKind: .iphonePWA,
                mode: .clean, route: "cloud_fallback", cleanup: "none"
            ),
            HistorySyncOperation(opID: UUID(), type: .edit, entryID: desktop.id, baseRevision: 1, text: "edited desktop"),
            HistorySyncOperation(opID: UUID(), type: .pin, entryID: desktop.id, baseRevision: 1),
            HistorySyncOperation(opID: UUID(), type: .delete, entryID: UUID(), baseRevision: 1),
            HistorySyncOperation(opID: UUID(), type: .edit, entryID: UUID(), baseRevision: 1, text: "x"),
            HistorySyncOperation(opID: UUID(), type: .import, entryID: UUID(), text: "", sourceKind: .iphonePWA, mode: .clean, route: "cloud_fallback"),
            HistorySyncOperation(opID: UUID(), type: .import, entryID: UUID(), text: "desktop kind is invalid", sourceKind: .desktop, mode: .clean, route: "mac_local"),
        ]))

        #expect(result.results.map(\.status) == [.applied, .applied, .conflict, .alreadyApplied, .missing, .invalid, .invalid])
        #expect(result.revision == before + 1)
        let imported = try #require(result.results[0].entry)
        #expect(imported.sourceKind == .iphonePWA)
        #expect(imported.remoteRoute == "cloud_fallback")
        #expect(imported.displayText == "from the phone")
        #expect(imported.createdAt == Date(timeIntervalSinceReferenceDate: 10))
        #expect(result.results[1].entry?.displayText == "edited desktop")
        #expect(result.results[1].entry?.entryRevision == 2)
        #expect(result.results[2].entry?.entryRevision == 2)

        // Replaying the import op is a no-op, and a fresh op on the same entry id is already_applied too.
        let replay = try await store.applySyncOperations(HistorySyncOperationBatch(operations: [
            HistorySyncOperation(opID: importOp, type: .import, entryID: importID, text: "changed", sourceKind: .iphonePWA, mode: .clean, route: "cloud_fallback"),
            HistorySyncOperation(opID: UUID(), type: .import, entryID: importID, text: "changed", sourceKind: .iphonePWA, mode: .clean, route: "cloud_fallback"),
            HistorySyncOperation(opID: UUID(), type: .pin, entryID: desktop.id, baseRevision: 2),
            HistorySyncOperation(opID: UUID(), type: .delete, entryID: desktop.id, baseRevision: 2),
        ]))
        #expect(replay.results.map(\.status) == [.alreadyApplied, .alreadyApplied, .applied, .conflict])
        #expect(replay.results[0].entry?.rawText == "from the phone")
        #expect(replay.revision == before + 2)
        #expect(try await store.fetch(id: desktop.id)?.isPinned == true)

        let deletion = try await store.applySyncOperations(HistorySyncOperationBatch(operations: [
            HistorySyncOperation(opID: UUID(), type: .delete, entryID: desktop.id, baseRevision: 3),
        ]))
        #expect(deletion.results.map(\.status) == [.applied])
        #expect(try await store.fetch(id: desktop.id) == nil)

        await #expect(throws: HistorySyncError.invalidRequest) {
            _ = try await store.applySyncOperations(HistorySyncOperationBatch(operations: []))
        }
    }

    @Test("history DTO uses the public snake-case wire format")
    func dtoWireFormat() async throws {
        let store = try HistoryStore.inMemory()
        let id = UUID()
        let saved = try await store.saveRemote(makeRemote(id: id, raw: "raw", polished: "Polished."))
        let data = try HistorySyncJSON.makeEncoder().encode(HistorySyncEntry(saved.entry))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["id"] as? String == id.uuidString.lowercased())
        #expect(object["source_kind"] as? String == "iphone_shortcut")
        #expect(object["display_text"] as? String == "Polished.")
        #expect(object["remote_route"] as? String == "mac_local")
        #expect(object["is_pinned"] as? Bool == false)
        #expect(object["entry_revision"] as? Int == 1)
        #expect(object.keys.contains("user_edited_text"))
        #expect(object.keys.contains("destination_display_name"))
        let createdAt = try #require(object["created_at"] as? String)
        #expect(createdAt.hasSuffix("Z"))
        #expect(createdAt.contains("."))
        for forbidden in ["bundle", "error", "latency", "token", "secret"] {
            #expect(!object.keys.contains { $0.localizedCaseInsensitiveContains(forbidden) })
        }

        let decoded = try HistorySyncJSON.makeDecoder().decode(HistorySyncEntry.self, from: data)
        #expect(decoded == HistorySyncEntry(saved.entry))

        let batchJSON = """
            {"operations":[{"op_id":"\(UUID().uuidString)","type":"import","entry_id":"\(UUID().uuidString)",
            "created_at":"2026-09-06T17:20:00Z","source_kind":"iphone_shortcut","mode":"clean","text":"hi",
            "route":"cloud_fallback","cleanup":"none"}]}
            """
        let batch = try HistorySyncJSON.makeDecoder().decode(HistorySyncOperationBatch.self, from: Data(batchJSON.utf8))
        #expect(batch.operations.count == 1)
        #expect(batch.operations[0].type == .import)
        #expect(batch.operations[0].createdAt != nil)
    }

    private func makeRemote(id: UUID, raw: String, polished: String?) -> HistoryRemoteCapture {
        HistoryRemoteCapture(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.125),
            rawText: raw,
            polishedText: polished,
            mode: .clean,
            sourceKind: .iphoneShortcut,
            remoteRoute: "mac_local",
            cleanupBackend: "deterministic",
            refinementStatus: .succeeded,
            asrLatency: 0.4,
            refinementLatency: 0.1,
            totalLatency: 0.6,
            asrSelection: "parakeet_v2"
        )
    }
}
