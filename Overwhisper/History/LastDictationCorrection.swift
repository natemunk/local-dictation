import Foundation

/// One explicit desktop history reference, never transcript or clipboard state.
struct LastDictationCorrection {
    private(set) var historyID: UUID?

    mutating func consider(id: UUID?, source: HistorySourceKind = .desktop,
                           deliveryCommitted: Bool, hasText: Bool, secure: Bool) {
        guard let id, source == .desktop, deliveryCommitted, hasText, !secure else { return }
        historyID = id
    }

    mutating func invalidate(_ id: UUID) {
        if historyID == id { historyID = nil }
    }

    mutating func clear() { historyID = nil }

    func canOpen(dictationActive: Bool, rewriteActive: Bool) -> Bool {
        historyID != nil && !dictationActive && !rewriteActive
    }

    func accepts(_ entry: HistoryEntry?) -> Bool {
        guard let entry, entry.id == historyID, entry.sourceKind == .desktop,
              entry.deliveryStatus != .cancelled, !entry.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }
}
