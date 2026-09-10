import Foundation

struct IPhoneAudioStreamRequest: Equatable, Sendable {
    let requestID: UUID
    let mode: CleanupMode
    let allowsCloudFallback: Bool
    let client: IPhoneDictationClient
}

enum IPhoneStreamControl: Equatable, Sendable {
    case finish(durationSeconds: TimeInterval)
    case cancel

    private struct Payload: Decodable {
        let type: String
        let durationSeconds: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case type
            case durationSeconds = "duration_seconds"
        }
    }

    static func decode(_ text: String) throws -> Self {
        guard let data = text.data(using: .utf8) else {
            throw IPhoneEndpointFailure(.invalidRequest)
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw IPhoneEndpointFailure(.invalidRequest)
        }
        switch payload.type {
        case "cancel":
            return .cancel
        case "finish":
            guard let duration = payload.durationSeconds,
                  duration.isFinite,
                  duration > 0,
                  duration <= IPhoneTranscriptionRequest.maximumDurationSeconds
            else { throw IPhoneEndpointFailure(.invalidRequest) }
            return .finish(durationSeconds: duration)
        default:
            throw IPhoneEndpointFailure(.invalidRequest)
        }
    }
}

enum IPhoneStreamServerMessage: Encodable, Equatable, Sendable {
    case ready(requestID: UUID)
    case audioReceived(requestID: UUID, frames: Int, partials: Int)
    case previewUnavailable(requestID: UUID)
    case partial(requestID: UUID, text: String)
    case final(IPhoneTranscriptionResponse)
    case error(requestID: UUID, kind: IPhoneEndpointErrorKind)

    enum CodingKeys: String, CodingKey {
        case type
        case requestID = "request_id"
        case text
        case route
        case cleanup
        case latencyMilliseconds = "latency_ms"
        case fallbackReason = "fallback_reason"
        case historyState = "history_state"
        case error
        case receivedFrames = "received_frames"
        case partialCount = "partial_count"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready(let requestID):
            try container.encode("ready", forKey: .type)
            try container.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        case .audioReceived(let requestID, let frames, let partials):
            try container.encode("audio_received", forKey: .type)
            try container.encode(requestID.uuidString.lowercased(), forKey: .requestID)
            try container.encode(frames, forKey: .receivedFrames)
            try container.encode(partials, forKey: .partialCount)
        case .previewUnavailable(let requestID):
            try container.encode("preview_unavailable", forKey: .type)
            try container.encode(requestID.uuidString.lowercased(), forKey: .requestID)
        case .partial(let requestID, let text):
            try container.encode("partial", forKey: .type)
            try container.encode(requestID.uuidString.lowercased(), forKey: .requestID)
            try container.encode(text, forKey: .text)
        case .final(let response):
            try container.encode("final", forKey: .type)
            try container.encode(response.requestID.uuidString.lowercased(), forKey: .requestID)
            try container.encode(response.text, forKey: .text)
            try container.encode(response.route, forKey: .route)
            try container.encode(response.cleanup, forKey: .cleanup)
            try container.encode(response.latencyMilliseconds, forKey: .latencyMilliseconds)
            try container.encode(response.fallbackReason, forKey: .fallbackReason)
            try container.encode(response.historyState, forKey: .historyState)
        case .error(let requestID, let kind):
            try container.encode("error", forKey: .type)
            try container.encode(requestID.uuidString.lowercased(), forKey: .requestID)
            try container.encode(kind, forKey: .error)
        }
    }
}

struct IPhoneAudioStreamSession: Sendable {
    let events: AsyncStream<IPhoneStreamServerMessage>
    let receiveAudio: @Sendable (Data) async throws -> Void
    let finish: @Sendable (TimeInterval) async throws -> Void
    let cancel: @Sendable () async -> Void
}
