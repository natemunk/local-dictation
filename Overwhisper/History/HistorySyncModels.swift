import Foundation

/// Where a history entry originated. Persisted as a stable string.
enum HistorySourceKind: String, Codable, CaseIterable, Sendable {
    case desktop
    case iphoneShortcut = "iphone_shortcut"
    case iphonePWA = "iphone_pwa"
}

/// Client identity carried on iPhone transcription requests.
enum IPhoneDictationClient: String, Codable, Equatable, Sendable {
    case shortcut
    case pwa

    var sourceKind: HistorySourceKind {
        switch self {
        case .shortcut: .iphoneShortcut
        case .pwa: .iphonePWA
        }
    }
}

/// Whether the Mac persisted a remote transcription.
enum IPhoneHistoryState: String, Codable, Equatable, Sendable {
    case savedOnMac = "saved_on_mac"
    case pendingDeviceSync = "pending_device_sync"
    case disabled
}

/// Public history DTO. Deliberately excludes bundle identifiers, error text,
/// latencies, credentials, and diagnostics. See docs/unified-history.md §3.
struct HistorySyncEntry: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let sourceKind: HistorySourceKind
    let mode: HistoryDictationMode
    let rawText: String
    let polishedText: String?
    let userEditedText: String?
    let displayText: String
    let destinationDisplayName: String?
    let remoteRoute: String?
    let cleanupBackend: String?
    let isPinned: Bool
    let entryRevision: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sourceKind = "source_kind"
        case mode
        case rawText = "raw_text"
        case polishedText = "polished_text"
        case userEditedText = "user_edited_text"
        case displayText = "display_text"
        case destinationDisplayName = "destination_display_name"
        case remoteRoute = "remote_route"
        case cleanupBackend = "cleanup_backend"
        case isPinned = "is_pinned"
        case entryRevision = "entry_revision"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(mode, forKey: .mode)
        try container.encode(rawText, forKey: .rawText)
        try container.encode(polishedText, forKey: .polishedText)
        try container.encode(userEditedText, forKey: .userEditedText)
        try container.encode(displayText, forKey: .displayText)
        try container.encode(destinationDisplayName, forKey: .destinationDisplayName)
        try container.encode(remoteRoute, forKey: .remoteRoute)
        try container.encode(cleanupBackend, forKey: .cleanupBackend)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(entryRevision, forKey: .entryRevision)
    }
}

struct HistorySyncRetention: Codable, Equatable, Sendable {
    let unpinnedDays: Int
    let pinned: String

    enum CodingKeys: String, CodingKey {
        case unpinnedDays = "unpinned_days"
        case pinned
    }

    static func standard(unpinnedDays: Int) -> HistorySyncRetention {
        HistorySyncRetention(unpinnedDays: unpinnedDays, pinned: "until_unpinned_or_deleted")
    }
}

struct HistorySyncManifest: Codable, Equatable, Sendable {
    static let maximumOperationsPerRequest = 100
    static let maximumTextCharacters = 100_000
    static let maximumPageSize = 100

    let revision: Int64
    let entryCount: Int
    let pinnedCount: Int
    let retention: HistorySyncRetention
    let maxOperationsPerRequest: Int
    let maxTextCharacters: Int

    enum CodingKeys: String, CodingKey {
        case revision
        case entryCount = "entry_count"
        case pinnedCount = "pinned_count"
        case retention
        case maxOperationsPerRequest = "max_operations_per_request"
        case maxTextCharacters = "max_text_characters"
    }
}

struct HistorySyncPage: Codable, Equatable, Sendable {
    let revision: Int64
    let entries: [HistorySyncEntry]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case revision
        case entries
        case nextCursor = "next_cursor"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(entries, forKey: .entries)
        try container.encode(nextCursor, forKey: .nextCursor)
    }
}

enum HistorySyncOperationType: String, Codable, Equatable, Sendable {
    case `import`
    case edit
    case pin
    case unpin
    case delete
}

/// One client operation. Fields that do not apply to `type` are ignored.
struct HistorySyncOperation: Codable, Equatable, Sendable {
    let opID: UUID
    let type: HistorySyncOperationType
    let entryID: UUID
    let baseRevision: Int64?
    let text: String?
    let createdAt: Date?
    let sourceKind: HistorySourceKind?
    let mode: HistoryDictationMode?
    let route: String?
    let cleanup: String?

    init(
        opID: UUID,
        type: HistorySyncOperationType,
        entryID: UUID,
        baseRevision: Int64? = nil,
        text: String? = nil,
        createdAt: Date? = nil,
        sourceKind: HistorySourceKind? = nil,
        mode: HistoryDictationMode? = nil,
        route: String? = nil,
        cleanup: String? = nil
    ) {
        self.opID = opID
        self.type = type
        self.entryID = entryID
        self.baseRevision = baseRevision
        self.text = text
        self.createdAt = createdAt
        self.sourceKind = sourceKind
        self.mode = mode
        self.route = route
        self.cleanup = cleanup
    }

    enum CodingKeys: String, CodingKey {
        case opID = "op_id"
        case type
        case entryID = "entry_id"
        case baseRevision = "base_revision"
        case text
        case createdAt = "created_at"
        case sourceKind = "source_kind"
        case mode
        case route
        case cleanup
    }
}

struct HistorySyncOperationBatch: Codable, Equatable, Sendable {
    let operations: [HistorySyncOperation]
}

enum HistorySyncOperationStatus: String, Codable, Equatable, Sendable {
    case applied
    case alreadyApplied = "already_applied"
    case missing
    case conflict
    case invalid
}

struct HistorySyncOperationResult: Codable, Equatable, Sendable {
    let opID: UUID
    let status: HistorySyncOperationStatus
    let entry: HistorySyncEntry?

    enum CodingKeys: String, CodingKey {
        case opID = "op_id"
        case status
        case entry
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opID.uuidString.lowercased(), forKey: .opID)
        try container.encode(status, forKey: .status)
        try container.encode(entry, forKey: .entry)
    }
}

struct HistorySyncOperationBatchResult: Codable, Equatable, Sendable {
    let revision: Int64
    let results: [HistorySyncOperationResult]
}

enum HistorySyncError: Error, Equatable, Sendable {
    case historyDisabled
    case historyChanged(currentRevision: Int64)
    case invalidRequest
    case payloadTooLarge
}

/// The seam between the HTTP listener and the history store. `nil` provider
/// means unified history is disabled and routes answer `history_disabled`.
protocol HistorySyncProviding: Sendable {
    func manifest() async throws -> HistorySyncManifest
    func page(revision: Int64, cursor: String?, limit: Int) async throws -> HistorySyncPage
    func apply(_ batch: HistorySyncOperationBatch) async throws -> HistorySyncOperationBatchResult
}

enum HistorySyncJSON {
    /// Shared wire format: ISO 8601 UTC with fractional seconds, snake_case keys
    /// handled by explicit CodingKeys, `null` emitted for absent optionals.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.formatter.date(from: value) ?? Self.fallbackFormatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 timestamp."
            )
        }
        return decoder
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
