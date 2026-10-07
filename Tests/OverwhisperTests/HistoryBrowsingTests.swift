import Foundation
import Testing
@testable import LocalDictation

@Suite("History browsing")
struct HistoryBrowsingTests {
    @Test("keyset pages keep equal timestamps ordered without duplicates")
    func equalTimestampPagination() async throws {
        let store = try HistoryStore.inMemory()
        let timestamp = Date(timeIntervalSince1970: 10_000)
        let ids = try await saveEntries(
            in: store,
            ids: ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003"],
            timestamps: [timestamp, timestamp, timestamp]
        )

        let first = try await store.browse(limit: 2)
        #expect(first.entries.map(\.id) == [ids[2], ids[1]])
        let second = try #require(first.nextCursor)
        let next = try await store.browse(cursor: second, limit: 2)
        #expect(next.entries.map(\.id) == [ids[0]])
        #expect(Set(first.entries.map(\.id)).isDisjoint(with: next.entries.map(\.id)))
        #expect(next.nextCursor == nil)
    }

    @Test("newer insertion waits for refresh while older insertion remains eligible")
    func insertionBetweenPages() async throws {
        let store = try HistoryStore.inMemory()
        let dates = [
            Date(timeIntervalSince1970: 30),
            Date(timeIntervalSince1970: 20),
            Date(timeIntervalSince1970: 10),
        ]
        let ids = try await saveEntries(
            in: store,
            ids: ["00000000-0000-0000-0000-000000000030", "00000000-0000-0000-0000-000000000020", "00000000-0000-0000-0000-000000000010"],
            timestamps: dates
        )

        let first = try await store.browse(limit: 2)
        let cursor = try #require(first.nextCursor)
        let newer = try await store.saveRaw(
            HistoryRawCapture(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000040")!,
                timestamp: Date(timeIntervalSince1970: 40),
                rawText: "newer",
                mode: .literal
            )
        )
        let older = try await store.saveRaw(
            HistoryRawCapture(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                timestamp: Date(timeIntervalSince1970: 5),
                rawText: "older",
                mode: .literal
            )
        )

        let next = try await store.browse(cursor: cursor, limit: 2)
        #expect(next.entries.map(\.id) == [ids[2], older.id])
        #expect(!next.entries.contains { $0.id == newer.id })

        let refreshed = try await store.browse(limit: 2)
        #expect(refreshed.entries.map(\.id) == [newer.id, ids[0]])
    }

    @Test("deleting the cursor row does not skip the following row")
    func deletionBetweenPages() async throws {
        let store = try HistoryStore.inMemory()
        let timestamp = Date(timeIntervalSince1970: 20_000)
        let ids = try await saveEntries(
            in: store,
            ids: ["00000000-0000-0000-0000-000000000101", "00000000-0000-0000-0000-000000000102", "00000000-0000-0000-0000-000000000103"],
            timestamps: [timestamp, timestamp, timestamp]
        )

        let first = try await store.browse(limit: 2)
        let cursor = try #require(first.nextCursor)
        _ = try await store.delete(id: cursor.id)
        let next = try await store.browse(cursor: cursor, limit: 2)
        #expect(next.entries.map(\.id) == [ids[0]])
    }

    @Test("pinned and clipboard recovery filters are applied in SQL")
    func filters() async throws {
        let store = try HistoryStore.inMemory()
        let pinned = try await store.saveRaw(
            HistoryRawCapture(rawText: "pinned", mode: .literal)
        )
        _ = try await store.setPinned(id: pinned.id, true, baseRevision: pinned.entryRevision)

        let clipboard = try await store.saveRaw(
            HistoryRawCapture(rawText: "clipboard recovery", mode: .literal)
        )
        _ = try await store.updateDelivery(
            id: clipboard.id,
            with: HistoryDeliveryUpdate(
                status: .clipboardOnly,
                deliveredText: clipboard.rawText
            )
        )

        let historyOnly = try await store.saveRaw(
            HistoryRawCapture(rawText: "history recovery", mode: .literal)
        )
        _ = try await store.updateDelivery(
            id: historyOnly.id,
            with: HistoryDeliveryUpdate(
                status: .historyOnly,
                deliveredText: historyOnly.rawText
            )
        )

        let ordinary = try await store.saveRaw(
            HistoryRawCapture(rawText: "ordinary", mode: .literal)
        )

        #expect(try await store.browse(filter: .pinned).entries.map(\.id) == [pinned.id])
        #expect(Set(try await store.browse(filter: .clipboardRecovery).entries.map(\.id)) == [clipboard.id, historyOnly.id])
        #expect(Set(try await store.browse().entries.map(\.id)) == [pinned.id, clipboard.id, historyOnly.id, ordinary.id])
    }

    @Test("refresh removes rows deleted by an external history operation")
    @MainActor
    func refreshRemovesExternallyDeletedRows() async throws {
        let store = try HistoryStore.inMemory()
        _ = try await store.saveRaw(HistoryRawCapture(rawText: "first", mode: .literal))
        _ = try await store.saveRaw(HistoryRawCapture(rawText: "second", mode: .literal))
        let model = makeModel(store)

        model.reload()
        try await waitForLoad(model)
        #expect(model.entries.count == 2)
        model.selection = model.entries[0].id
        model.beginEditing()
        model.editDraft = "unsaved draft"

        _ = try await store.deleteTranscriptHistory()
        model.refresh()
        try await waitForLoad(model)

        #expect(model.entries.isEmpty)
        #expect(model.selection == nil)
        #expect(!model.isEditing)
        #expect(model.editDraft.isEmpty)
    }

    @Test("refresh applies an external unpin while browsing pinned entries")
    @MainActor
    func refreshRemovesExternallyUnpinnedRow() async throws {
        let store = try HistoryStore.inMemory()
        let entry = try await store.saveRaw(
            HistoryRawCapture(rawText: "pinned then unpinned", mode: .literal)
        )
        _ = try await store.setPinned(id: entry.id, true, baseRevision: entry.entryRevision)
        let model = makeModel(store)
        model.browseFilter = .pinned

        model.reload()
        try await waitForLoad(model)
        #expect(model.entries.map(\.id) == [entry.id])

        let pinnedEntry = try #require(try await store.fetch(id: entry.id))
        _ = try await store.setPinned(id: entry.id, false, baseRevision: pinnedEntry.entryRevision)
        model.refresh()
        try await waitForLoad(model)

        #expect(model.entries.isEmpty)
        #expect(model.selection == nil)
    }

    @Test("refresh updates existing rows without resetting an edit draft")
    @MainActor
    func refreshRereadsExistingRows() async throws {
        let store = try HistoryStore.inMemory()
        let entry = try await store.saveRaw(
            HistoryRawCapture(rawText: "original", mode: .literal)
        )
        let model = makeModel(store)

        model.reload()
        try await waitForLoad(model)
        model.selection = entry.id
        model.beginEditing()
        model.editDraft = "local unsaved draft"

        _ = try await store.setUserEditedText(
            id: entry.id,
            text: "changed elsewhere",
            baseRevision: entry.entryRevision
        )
        model.refresh()
        try await waitForLoad(model)

        #expect(model.entries.first?.displayText == "changed elsewhere")
        #expect(model.isEditing)
        #expect(model.editDraft == "local unsaved draft")
    }

    @MainActor
    private func makeModel(_ store: HistoryStore) -> HistoryViewModel {
        HistoryViewModel(
            store: store,
            onCopy: { _ in },
            onRepaste: { _ in },
            onAddVocabularyCorrection: { _ in }
        )
    }

    @Test @MainActor func bulkRefreshFillsGapAndDoesNotDuplicateLoadedPages() async throws {
        let store = try HistoryStore.inMemory()
        for index in 0..<120 {
            _ = try await store.saveRaw(.init(timestamp: Date(timeIntervalSince1970: Double(index)),
                                              rawText: "Synthetic old entry", mode: .literal))
        }
        let model = makeModel(store)
        model.reload()
        try await waitForLoad(model)
        model.loadMore()
        try await waitForLoad(model)
        #expect(model.entries.count == 120)
        #expect(!model.hasMore)
        for index in 0..<150 {
            _ = try await store.saveRaw(.init(timestamp: Date(timeIntervalSince1970: Double(1000 + index)),
                                              rawText: "Synthetic new entry", mode: .literal))
        }
        model.refresh()
        try await waitForLoad(model)
        for _ in 0..<5 where model.hasMore {
            model.loadMore()
            try await waitForLoad(model)
        }
        #expect(!model.hasMore)
        #expect(model.entries.count == 270)
        #expect(Set(model.entries.map(\.id)).count == 270)
        #expect(model.entries.map(\.timestamp) == model.entries.map(\.timestamp).sorted(by: >))
    }

    @Test @MainActor func deletionClearRejectsPendingReloadAndErasesDraft() async throws {
        let store = try HistoryStore.inMemory()
        _ = try await store.saveRaw(.init(rawText: "Synthetic retained entry", mode: .literal))
        let model = makeModel(store)
        model.reload()
        try await waitForLoad(model)
        model.beginEditing()
        model.editDraft = "Synthetic unsaved edit"
        _ = try await store.deleteEverything()
        model.refresh()
        model.clearForDeletion()
        await Task.yield()
        _ = try await store.browse()
        #expect(model.entries.isEmpty)
        #expect(model.selectedEntry == nil)
        #expect(model.editDraft.isEmpty)
        #expect(!model.isEditing)
        #expect(!model.isLoading)
        #expect(!model.hasMore)
    }

    @MainActor
    private func waitForLoad(_ model: HistoryViewModel) async throws {
        for _ in 0..<2_000 {
            if !model.isLoading { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for history browsing operation")
    }

    private func saveEntries(
        in store: HistoryStore,
        ids: [String],
        timestamps: [Date]
    ) async throws -> [UUID] {
        try #require(ids.count == timestamps.count)
        var saved = [UUID]()
        for (id, timestamp) in zip(ids, timestamps) {
            let entry = try await store.saveRaw(
                HistoryRawCapture(
                    id: try #require(UUID(uuidString: id)),
                    timestamp: timestamp,
                    rawText: id,
                    mode: .literal
                )
            )
            saved.append(entry.id)
        }
        return saved
    }
}
