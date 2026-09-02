import Foundation

/// Runtime ownership for one dictation generation.
///
/// Keeping every session-scoped task and artifact on this value makes stale
/// asynchronous work mechanically unable to replace a newer generation.
struct DictationSession {
    let token: DictationSessionToken
    let startedAt: Date
    let engine: (any TranscriptionEngine)?
    let streamingTranscriber: (any StreamingTranscriber)?
    let asrSelection: ASRSelection
    var state: DictationPhase = .recording
    var destination: DictationDestination?
    var profile: DictationProfile
    var rawText = ""
    var deliveredText = ""
    var historyID: UUID?
    var refinementStatus: HistoryRefinementStatus = .notRequested
    var asrOutcome = "final"
    var refinerBackend: String?
    var refinementOutcome: String?
    var validationFailureKind: String?
    var refinementError: String?
    var stoppedAt: Date?
    var metricTiming = DictationMetricTiming()
    var metricDictationMode: HistoryDictationMode?
    var metricSpeechEngine: String?
    var metricSpeechModel: String?
    var metricCleanupBackend: String?
    var recognizedCommandCount: Int?
    var metricEventRevision: Int64 = 0
    var pastedRaw = false
    var cleanupMode: CleanupMode = .clean
    var deliveryCommitted = false
    var interleavedTyping = false
    var cancellationRequested = false
    var warnedAtTenMinutes = false
    var durationCapTriggered = false
    var audioURL: URL?
    /// Owns the async destination-capture/recording-stop bridge. Keeping this
    /// task on the generation prevents a cancelled session from stopping a
    /// replacement recording after an Accessibility retry returns.
    var captureFinishTask: Task<Void, Never>?
    var finalizationTask: Task<Void, Never>?
    var streamingStartTask: Task<AsyncStream<TranscriptUpdate>?, Never>?
    var streamingUpdatesTask: Task<Void, Never>?
    var captureWatchdog: Task<Void, Never>?
    var finalizationWatchdog: Task<Void, Never>?
}

/// The sole mutable owner of the app's active dictation generation.
@MainActor
final class DictationSessionController {
    private(set) var active: DictationSession?

    func install(_ session: DictationSession) {
        active = session
    }

    func matches(_ token: DictationSessionToken) -> Bool {
        active?.token == token
    }

    func isCurrent(_ token: DictationSessionToken) -> Bool {
        guard let active else { return false }
        return active.token == token && !active.cancellationRequested
    }

    @discardableResult
    func update(
        _ token: DictationSessionToken,
        _ mutation: (inout DictationSession) -> Void
    ) -> Bool {
        guard var session = active, session.token == token else { return false }
        mutation(&session)
        active = session
        return true
    }

    /// Clears only the generation named by `token`. A stale completion cannot
    /// retire a newer session.
    @discardableResult
    func clear(_ token: DictationSessionToken) -> DictationSession? {
        guard let session = active, session.token == token else { return nil }
        active = nil
        return session
    }
}
