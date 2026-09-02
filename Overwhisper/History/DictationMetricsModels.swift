import Foundation

enum DictationMetricSourceKind: String, Codable, Sendable {
    case measured
    case legacyHistory = "legacy_history"
}

/// Monotonic lifecycle timestamps for one dictation attempt.
///
/// `ProcessInfo.systemUptime` is used by production callers. Tests can provide
/// exact synthetic uptime values without sleeping or consulting wall time.
struct DictationMetricTiming: Equatable, Sendable {
    private(set) var recordingStartedAtUptime: TimeInterval?
    private(set) var recordingStoppedAtUptime: TimeInterval?
    private(set) var asrCompletedAtUptime: TimeInterval?
    private(set) var cleanupStartedAtUptime: TimeInterval?
    private(set) var cleanupCompletedAtUptime: TimeInterval?

    init(recordingStartedAtUptime: TimeInterval? = nil) {
        self.recordingStartedAtUptime = recordingStartedAtUptime
    }

    mutating func markRecordingStarted(at uptime: TimeInterval) {
        guard recordingStartedAtUptime == nil else { return }
        recordingStartedAtUptime = uptime
    }

    mutating func markRecordingStopped(at uptime: TimeInterval) {
        guard recordingStoppedAtUptime == nil else { return }
        recordingStoppedAtUptime = max(recordingStartedAtUptime ?? uptime, uptime)
    }

    mutating func markASRCompleted(at uptime: TimeInterval) {
        guard asrCompletedAtUptime == nil else { return }
        asrCompletedAtUptime = max(recordingStoppedAtUptime ?? uptime, uptime)
    }

    mutating func markCleanupStarted(at uptime: TimeInterval) {
        guard cleanupStartedAtUptime == nil else { return }
        cleanupStartedAtUptime = max(asrCompletedAtUptime ?? uptime, uptime)
    }

    mutating func markCleanupCompleted(at uptime: TimeInterval) {
        guard cleanupCompletedAtUptime == nil else { return }
        cleanupCompletedAtUptime = max(cleanupStartedAtUptime ?? uptime, uptime)
    }

    var recordingDurationSeconds: TimeInterval? {
        guard let recordingStartedAtUptime, let recordingStoppedAtUptime else { return nil }
        return max(0, recordingStoppedAtUptime - recordingStartedAtUptime)
    }

    var asrLatencySeconds: TimeInterval? {
        guard let recordingStoppedAtUptime, let asrCompletedAtUptime else { return nil }
        return max(0, asrCompletedAtUptime - recordingStoppedAtUptime)
    }

    var cleanupLatencySeconds: TimeInterval? {
        guard let cleanupStartedAtUptime, let cleanupCompletedAtUptime else { return nil }
        return max(0, cleanupCompletedAtUptime - cleanupStartedAtUptime)
    }

    func stopToDeliveryLatencySeconds(completedAtUptime: TimeInterval) -> TimeInterval? {
        guard let recordingStoppedAtUptime else { return nil }
        return max(0, completedAtUptime - recordingStoppedAtUptime)
    }
}

/// One transcript-free analytics row. Text is accepted only by the caller's
/// local word-counting step and has no representation in this type.
struct DictationMetricEvent: Equatable, Sendable {
    static let currentSchemaVersion = 1

    let eventID: UUID
    let completedAt: Date
    let recordingDurationSeconds: TimeInterval?
    let rawWordCount: Int
    let deliveredWordCount: Int
    let dictationMode: String?
    let speechEngine: String?
    let speechModel: String?
    let cleanupBackend: String?
    let cleanupOutcome: String?
    let asrLatencySeconds: TimeInterval?
    let cleanupLatencySeconds: TimeInterval?
    let stopToDeliveryLatencySeconds: TimeInterval?
    let deliveryOutcome: String
    let recognizedCommandCount: Int?
    let wordsRemoved: Int?
    let destinationBundleIdentifier: String?
    let destinationDisplayName: String?
    let sourceKind: DictationMetricSourceKind
    let timingComplete: Bool
    let eventRevision: Int64
    let schemaVersion: Int
}

enum DictationWordCounter {
    /// Whitespace-delimited counting keeps identifiers, URLs, and ticket IDs as
    /// one dictated unit while ignoring punctuation-only fragments.
    static func count(_ text: String) -> Int {
        text.split(whereSeparator: \Character.isWhitespace).reduce(into: 0) { count, token in
            if token.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                count += 1
            }
        }
    }
}

struct DictationMetricDestinationMetadata: Equatable, Sendable {
    let bundleIdentifier: String?
    let displayName: String?

    init(
        bundleIdentifier: String?,
        displayName: String?,
        analyticsEnabled: Bool
    ) {
        guard analyticsEnabled else {
            self.bundleIdentifier = nil
            self.displayName = nil
            return
        }
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}
