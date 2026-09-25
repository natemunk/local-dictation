import Foundation
import GRDB

enum DictationMetricPhase: String, CaseIterable, Sendable {
    case captureReady = "hotkey_to_capture_ready_seconds"
    case captureStop = "capture_stop_seconds"
    case destinationCapture = "destination_capture_seconds"
    case drainWait = "remaining_drain_wait_seconds"
    case leaseWait = "inference_lease_wait_seconds"
    case inference = "engine_transcription_seconds"
    case rawHistory = "raw_history_write_seconds"
    case preparedHistory = "pre_delivery_history_seconds"
    case pasteValidation = "paste_validation_seconds"
    case pasteEvent = "stop_to_paste_event_seconds"
}

enum DestinationCaptureOutcome: String, Sendable {
    case captured
    case noForegroundApp = "no_foreground_app"
    case noEligibleDestination = "no_eligible_destination"
    case cancelled
}

/// Optional v2 measurements. Old rows and unattempted phases stay absent.
struct DictationMetricDetails: Equatable, Sendable {
    var durations: [DictationMetricPhase: Double] = [:]
    var insertionFailure: InsertionDiagnosticFailureKind?
    var insertionTier: DestinationInsertionTier?
    var captureOutcome: DestinationCaptureOutcome?
    var cleanupFallbackReason: String?
    var buildLabel: String?
    var foregroundBundleIdentifier: String?

    mutating func record(_ phase: DictationMetricPhase, from start: TimeInterval,
                         to end: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard start.isFinite, end.isFinite, end >= start else { return }
        durations[phase] = end - start
    }

    mutating func redactDestination(enabled: Bool) {
        if !enabled { foregroundBundleIdentifier = nil }
    }

    static let labelColumns = ["insertion_failure_kind", "insertion_tier", "capture_outcome",
                               "cleanup_fallback_reason", "build_label", "foreground_bundle_identifier"]
    static let columnNames = DictationMetricPhase.allCases.map(\.rawValue) + labelColumns

    var databaseValues: [DatabaseValue] {
        let durations = DictationMetricPhase.allCases.map { phase -> DatabaseValue in
            guard let value = self.durations[phase], value.isFinite, value >= 0 else { return .null }
            return value.databaseValue
        }
        let labels: [String?] = [insertionFailure?.rawValue, insertionTier?.rawValue,
                                captureOutcome?.rawValue, cleanupFallbackReason, buildLabel,
                                foregroundBundleIdentifier]
        return durations + labels.map { $0?.databaseValue ?? .null }
    }

    init() {}
    init(row: Row) {
        for phase in DictationMetricPhase.allCases {
            if let value: Double = row[phase.rawValue], value.isFinite, value >= 0 { durations[phase] = value }
        }
        insertionFailure = (row["insertion_failure_kind"] as String?).flatMap(InsertionDiagnosticFailureKind.init(rawValue:))
        insertionTier = (row["insertion_tier"] as String?).flatMap(DestinationInsertionTier.init(rawValue:))
        captureOutcome = (row["capture_outcome"] as String?).flatMap(DestinationCaptureOutcome.init(rawValue:))
        cleanupFallbackReason = row["cleanup_fallback_reason"]
        buildLabel = row["build_label"]
        foregroundBundleIdentifier = row["foreground_bundle_identifier"]
    }
}

enum LocalDictationBuild {
    static let label = Bundle.main.object(forInfoDictionaryKey: "LocalDictationBuildLabel") as? String ?? "dev/unknown"
}
