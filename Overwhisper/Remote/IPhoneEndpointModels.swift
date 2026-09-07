import Foundation

enum IPhoneEndpointLifecycleState: String, Codable, Equatable, Sendable {
    case disabled
    case starting
    case ready
    case failed
}

enum IPhoneTranscriptionRoute: String, Codable, Equatable, Sendable {
    case macLocal = "mac_local"
    case cloudFallback = "cloud_fallback"
}

enum IPhoneCleanupBackend: String, Codable, Equatable, Sendable {
    case appleFoundation = "apple_foundation"
    case deterministic
    case none
}

enum IPhoneFallbackReason: String, Codable, Equatable, Sendable {
    case macOffline = "mac_offline"
    case macBusy = "mac_busy"
    case macUnready = "mac_unready"
    case macTimeout = "mac_timeout"
    case localASRFailed = "local_asr_failed"
    case remotePreempted = "remote_preempted"
}

struct IPhoneTranscriptionRequest: Sendable {
    static let maximumBodyBytes = 12 * 1_024 * 1_024
    static let maximumDurationSeconds: TimeInterval = 10 * 60

    let requestID: UUID
    let mode: CleanupMode
    let allowsCloudFallback: Bool
    let claimedDurationSeconds: TimeInterval
    let mediaType: String
    let audio: Data
    var client: IPhoneDictationClient = .shortcut
}

struct IPhoneTranscriptionResponse: Codable, Equatable, Sendable {
    let requestID: UUID
    let text: String
    let route: IPhoneTranscriptionRoute
    let cleanup: IPhoneCleanupBackend
    let latencyMilliseconds: Int
    let fallbackReason: IPhoneFallbackReason?
    var historyState: IPhoneHistoryState = .disabled

    init(
        requestID: UUID,
        text: String,
        route: IPhoneTranscriptionRoute,
        cleanup: IPhoneCleanupBackend,
        latencyMilliseconds: Int,
        fallbackReason: IPhoneFallbackReason?,
        historyState: IPhoneHistoryState = .disabled
    ) {
        self.requestID = requestID
        self.text = text
        self.route = route
        self.cleanup = cleanup
        self.latencyMilliseconds = latencyMilliseconds
        self.fallbackReason = fallbackReason
        self.historyState = historyState
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case text
        case route
        case cleanup
        case latencyMilliseconds = "latency_ms"
        case fallbackReason = "fallback_reason"
        case historyState = "history_state"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        text = try container.decode(String.self, forKey: .text)
        route = try container.decode(IPhoneTranscriptionRoute.self, forKey: .route)
        cleanup = try container.decode(IPhoneCleanupBackend.self, forKey: .cleanup)
        latencyMilliseconds = try container.decode(Int.self, forKey: .latencyMilliseconds)
        fallbackReason = try container.decodeIfPresent(IPhoneFallbackReason.self, forKey: .fallbackReason)
        historyState = try container.decodeIfPresent(IPhoneHistoryState.self, forKey: .historyState) ?? .disabled
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        try container.encode(text, forKey: .text)
        try container.encode(route, forKey: .route)
        try container.encode(cleanup, forKey: .cleanup)
        try container.encode(latencyMilliseconds, forKey: .latencyMilliseconds)
        if let fallbackReason {
            try container.encode(fallbackReason, forKey: .fallbackReason)
        } else {
            try container.encodeNil(forKey: .fallbackReason)
        }
        try container.encode(historyState, forKey: .historyState)
    }
}

struct IPhoneEndpointHealthResponse: Codable, Equatable, Sendable {
    let ready: Bool
    let busy: Bool
    let selectedEngine: String?

    enum CodingKeys: String, CodingKey {
        case ready
        case busy
        case selectedEngine = "selected_engine"
    }
}

enum IPhoneEndpointErrorKind: String, Codable, Equatable, Sendable {
    case invalidRequest = "invalid_request"
    case unsupportedMedia = "unsupported_media"
    case payloadTooLarge = "payload_too_large"
    case durationTooLong = "duration_too_long"
    case engineUnavailable = "engine_unavailable"
    case desktopBusy = "desktop_busy"
    case remoteBusy = "remote_busy"
    case remotePreempted = "remote_preempted"
    case transcriptionFailed = "transcription_failed"
    case transcriptionTimedOut = "transcription_timed_out"
    case emptyTranscript = "empty_transcript"
}

struct IPhoneEndpointErrorResponse: Codable, Equatable, Sendable {
    let error: IPhoneEndpointErrorKind
}

struct IPhoneEndpointFailure: Error, Equatable, Sendable {
    let kind: IPhoneEndpointErrorKind

    init(_ kind: IPhoneEndpointErrorKind) {
        self.kind = kind
    }
}

struct IPhoneEndpointRuntimeSnapshot: Equatable, Sendable {
    var lifecycle: IPhoneEndpointLifecycleState = .disabled
    var listenerReady = false
    var tunnelReady: Bool?
    var activeRequest = false
    var lastRoute: IPhoneTranscriptionRoute?
    var lastFailure: IPhoneEndpointErrorKind?
}

struct IPhoneLocalProcessingResult: Sendable {
    let response: IPhoneTranscriptionResponse
    let rawWordCount: Int
    let deliveredWordCount: Int
    let audioDurationSeconds: TimeInterval
    let asrLatencySeconds: TimeInterval
    let cleanupLatencySeconds: TimeInterval?
    let recognizedCommandCount: Int
    let cleanupOutcome: String
}
