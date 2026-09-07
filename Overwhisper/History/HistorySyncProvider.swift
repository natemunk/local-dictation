import Foundation

extension HistorySyncEntry {
    /// Projects a stored entry onto the public DTO. Bundle identifiers, error
    /// text, latencies, and diagnostics deliberately never cross this seam.
    init(_ entry: HistoryEntry) {
        self.init(
            id: entry.id,
            createdAt: entry.timestamp,
            updatedAt: entry.updatedAt,
            sourceKind: entry.sourceKind,
            mode: entry.mode,
            rawText: entry.rawText,
            polishedText: entry.polishedText,
            userEditedText: entry.userEditedText,
            displayText: entry.displayText,
            destinationDisplayName: entry.sourceKind == .desktop ? entry.destinationDisplayName : nil,
            remoteRoute: entry.remoteRoute,
            cleanupBackend: entry.cleanupBackend,
            isPinned: entry.isPinned,
            entryRevision: entry.entryRevision
        )
    }
}

/// Serves the unified-history routes from the actor-isolated store. Every
/// call runs on the store actor, never on `MainActor`.
struct HistoryStoreSyncProvider: HistorySyncProviding {
    let store: HistoryStore
    let retentionPolicy: HistoryRetentionPolicy

    init(store: HistoryStore, retentionPolicy: HistoryRetentionPolicy) {
        self.store = store
        self.retentionPolicy = retentionPolicy
    }

    func manifest() async throws -> HistorySyncManifest {
        try await store.syncManifest(policy: retentionPolicy)
    }

    func page(revision: Int64, cursor: String?, limit: Int) async throws -> HistorySyncPage {
        try await store.syncPage(revision: revision, cursor: cursor, limit: limit)
    }

    func apply(_ batch: HistorySyncOperationBatch) async throws -> HistorySyncOperationBatchResult {
        try await store.applySyncOperations(batch)
    }
}
