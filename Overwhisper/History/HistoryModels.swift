import Foundation

/// Stable values persisted in the history database. These are intentionally
/// independent from UI and coordinator types so history can evolve safely.
enum HistoryDictationMode: String, Codable, CaseIterable, Sendable {
    case clean = "clean"
    case literal = "literal"
}

enum HistoryDeliveryStatus: String, Codable, CaseIterable, Sendable {
    case pending = "pending"
    case delivered = "delivered"
    case previewed = "previewed"
    case pastedRaw = "pasted_raw"
    case pasteEventSent = "paste_event_sent"
    case clipboardOnly = "clipboard_only"
    case historyOnly = "history_only"
    case failed = "failed"
    case cancelled = "cancelled"

    var isSuccessful: Bool {
        self == .delivered
            || self == .previewed
            || self == .pastedRaw
            || self == .pasteEventSent
            || self == .clipboardOnly
    }
}

enum HistoryRefinementStatus: String, Codable, CaseIterable, Sendable {
    case pending = "pending"
    case notRequested = "not_requested"
    case succeeded = "succeeded"
    case failed = "failed"
    case retrying = "retrying"
}

/// The only destination metadata history accepts. Browser hostnames, URLs,
/// titles, and page content deliberately have no representation here.
struct HistoryDestination: Equatable, Sendable {
    var bundleIdentifier: String?
    var displayName: String?

    init(bundleIdentifier: String? = nil, displayName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

struct HistoryRawCapture: Equatable, Sendable {
    var id: UUID
    var timestamp: Date
    var rawText: String
    var destination: HistoryDestination
    var mode: HistoryDictationMode
    var refinementRequested: Bool
    var asrLatency: TimeInterval?
    var unrecognizedCommandCandidates: [String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        destination: HistoryDestination = HistoryDestination(),
        mode: HistoryDictationMode,
        refinementRequested: Bool? = nil,
        asrLatency: TimeInterval? = nil,
        unrecognizedCommandCandidates: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.destination = destination
        self.mode = mode
        self.refinementRequested = refinementRequested ?? (mode == .clean)
        self.asrLatency = asrLatency
        self.unrecognizedCommandCandidates = unrecognizedCommandCandidates
    }
}

struct HistoryFinalization: Equatable, Sendable {
    var polishedText: String?
    var refinementStatus: HistoryRefinementStatus
    var deliveryStatus: HistoryDeliveryStatus
    var refinementLatency: TimeInterval?
    var totalLatency: TimeInterval?
    var error: String?

    init(
        polishedText: String?,
        refinementStatus: HistoryRefinementStatus,
        deliveryStatus: HistoryDeliveryStatus,
        refinementLatency: TimeInterval? = nil,
        totalLatency: TimeInterval? = nil,
        error: String? = nil
    ) {
        self.polishedText = polishedText
        self.refinementStatus = refinementStatus
        self.deliveryStatus = deliveryStatus
        self.refinementLatency = refinementLatency
        self.totalLatency = totalLatency
        self.error = error
    }
}

struct HistoryDeliveryUpdate: Equatable, Sendable {
    var status: HistoryDeliveryStatus
    var deliveredText: String?
    var totalLatency: TimeInterval?
    var error: String?

    init(
        status: HistoryDeliveryStatus,
        deliveredText: String? = nil,
        totalLatency: TimeInterval? = nil,
        error: String? = nil
    ) {
        self.status = status
        self.deliveredText = deliveredText
        self.totalLatency = totalLatency
        self.error = error
    }
}

enum HistoryTextVersion: Sendable {
    case raw
    case polished
    case delivered
}

struct HistoryPolishRetry: Equatable, Sendable {
    let entryID: UUID
    let rawText: String
    let retryCount: Int
    let startedAt: Date
}

struct HistoryRetentionPolicy: Equatable, Sendable {
    static let defaultSuccessRetentionDays = 90
    static let `default` = HistoryRetentionPolicy()

    var successRetentionDays: Int

    init(successRetentionDays: Int = defaultSuccessRetentionDays) {
        self.successRetentionDays = successRetentionDays
    }
}

struct HistoryEntry: Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let rawText: String
    let polishedText: String?
    let destinationBundleIdentifier: String?
    let destinationDisplayName: String?
    let mode: HistoryDictationMode
    let deliveryStatus: HistoryDeliveryStatus
    let refinementStatus: HistoryRefinementStatus
    let asrLatency: TimeInterval?
    let refinementLatency: TimeInterval?
    let totalLatency: TimeInterval?
    let unrecognizedCommandCandidates: [String]
    let error: String?
    let polishRetryCount: Int
    let lastPolishAttemptAt: Date?

    var destination: HistoryDestination {
        HistoryDestination(
            bundleIdentifier: destinationBundleIdentifier,
            displayName: destinationDisplayName
        )
    }

    /// The exact text delivered to the destination. Literal and failed-polish
    /// entries fall back to the immutable raw transcript.
    var deliveredText: String {
        polishedText ?? rawText
    }

    func text(for version: HistoryTextVersion) -> String? {
        switch version {
        case .raw:
            rawText
        case .polished:
            polishedText
        case .delivered:
            deliveredText
        }
    }
}

enum HistoryStoreError: Error, Equatable, LocalizedError, Sendable {
    case entryNotFound(UUID)
    case invalidStoredValue(column: String, value: String)
    case polishRetryRequiresFailedEntry(UUID)
    case invalidRetentionDays(Int)

    var errorDescription: String? {
        switch self {
        case let .entryNotFound(id):
            "No dictation history entry exists for \(id.uuidString)."
        case let .invalidStoredValue(column, value):
            "Invalid stored history value '\(value)' in column '\(column)'."
        case let .polishRetryRequiresFailedEntry(id):
            "Dictation history entry \(id.uuidString) does not have failed polish metadata."
        case let .invalidRetentionDays(days):
            "History retention days must be nonnegative; received \(days)."
        }
    }
}
