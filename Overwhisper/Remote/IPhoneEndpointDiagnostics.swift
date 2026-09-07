import Foundation

/// A closed, transcript-free event written to the unified macOS log.
///
/// The type intentionally has no fields capable of carrying transcript text,
/// audio, credentials, headers, URLs, file paths, or raw error descriptions.
struct IPhoneEndpointDiagnosticEvent: Codable, Equatable, Sendable {
    let event: String
    let requestID: String
    let route: String
    let client: String
    let mode: String
    let mediaType: String
    let sizeBucket: String
    let durationBucket: String
    let status: Int
    let outcome: String
    let failureCode: String
    let cleanup: String
    let historyState: String
    let latencyMilliseconds: Int

    enum CodingKeys: String, CodingKey {
        case event
        case requestID = "request_id"
        case route
        case client
        case mode
        case mediaType = "media_type"
        case sizeBucket = "size_bucket"
        case durationBucket = "duration_bucket"
        case status
        case outcome
        case failureCode = "failure_code"
        case cleanup
        case historyState = "history_state"
        case latencyMilliseconds = "latency_ms"
    }

    static func make(
        event: String,
        request: IPhoneTranscriptionRequest? = nil,
        streamRequest: IPhoneAudioStreamRequest? = nil,
        requestID: UUID? = nil,
        route: String,
        status: Int = 0,
        outcome: String,
        failure: IPhoneEndpointErrorKind? = nil,
        cleanup: IPhoneCleanupBackend? = nil,
        historyState: IPhoneHistoryState? = nil,
        latencyMilliseconds: Int = 0
    ) -> Self {
        Self(
            event: event,
            requestID: (request?.requestID ?? streamRequest?.requestID ?? requestID)?
                .uuidString.lowercased() ?? "none",
            route: route,
            client: request?.client.rawValue ?? streamRequest?.client.rawValue ?? "none",
            mode: request?.mode.rawValue ?? streamRequest?.mode.rawValue ?? "none",
            mediaType: request?.mediaType ?? (streamRequest == nil ? "none" : "audio/pcm"),
            sizeBucket: sizeBucket(request?.audio.count),
            durationBucket: durationBucket(request?.claimedDurationSeconds),
            status: max(0, min(status, 599)),
            outcome: outcome,
            failureCode: failure?.rawValue ?? "none",
            cleanup: cleanup?.rawValue ?? "none",
            historyState: historyState?.rawValue ?? "none",
            latencyMilliseconds: max(0, latencyMilliseconds)
        )
    }

    func encodedLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let line = String(data: data, encoding: .utf8)
        else { return #"{"event":"diagnostic_encoding_failed"}"# }
        return line
    }

    private static func sizeBucket(_ byteCount: Int?) -> String {
        guard let byteCount, byteCount > 0 else { return "none" }
        if byteCount <= 256 * 1_024 { return "tiny" }
        if byteCount <= 1_024 * 1_024 { return "small" }
        if byteCount <= 4 * 1_024 * 1_024 { return "medium" }
        if byteCount <= IPhoneTranscriptionRequest.maximumBodyBytes { return "large" }
        return "oversized"
    }

    private static func durationBucket(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "none" }
        if seconds <= 15 { return "short" }
        if seconds <= 60 { return "medium" }
        if seconds <= 180 { return "long" }
        return "very_long"
    }
}

enum IPhoneEndpointDiagnostics {
    static func emit(_ event: IPhoneEndpointDiagnosticEvent) {
        let line = event.encodedLine()
        if event.outcome == "failed" {
            AppLogger.remote.error("\(line, privacy: .public)")
        } else if event.outcome == "degraded" {
            AppLogger.remote.warning("\(line, privacy: .public)")
        } else {
            AppLogger.remote.info("\(line, privacy: .public)")
        }
    }
}
