import Foundation

/// The small set of filters supported by the desktop history browser. Search
/// remains a separate, capped operation; these filters apply to cursor-paged
/// browsing when the search field is empty.
enum HistoryBrowseFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case pinned
    case clipboardRecovery = "clipboard_recovery"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .pinned: "Pinned"
        case .clipboardRecovery: "Clipboard recovery"
        }
    }

    func includes(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all: true
        case .pinned: entry.isPinned
        case .clipboardRecovery: entry.deliveryStatus == .clipboardOnly || entry.deliveryStatus == .historyOnly
        }
    }
}

/// A stable keyset cursor for the history order `(timestamp DESC, id DESC)`.
/// It deliberately contains no row offset, so inserts and deletes between
/// pages cannot cause an entry to be skipped or returned twice.
struct HistoryBrowseCursor: Equatable, Sendable {
    let timestamp: Date
    let id: UUID
}

struct HistoryBrowsePage: Equatable, Sendable {
    static let defaultPageSize = 100
    static let maximumPageSize = 100

    let entries: [HistoryEntry]
    let nextCursor: HistoryBrowseCursor?

    var hasMore: Bool { nextCursor != nil }
}

enum HistoryBrowsingError: Error, Equatable, LocalizedError, Sendable {
    case invalidPageSize(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidPageSize(size):
            "History page size must be between 1 and \(HistoryBrowsePage.maximumPageSize); received \(size)."
        }
    }
}
