import Foundation
#if canImport(LocalDictationSpeech)
import LocalDictationSpeech

typealias TranscriptBoundarySource = LocalDictationSpeech.TranscriptBoundarySource
typealias TranscriptBoundary = LocalDictationSpeech.TranscriptBoundary
typealias FinalTranscript = LocalDictationSpeech.FinalTranscript
typealias TimedTranscriptFragment = LocalDictationSpeech.TimedTranscriptFragment
typealias TranscriptBoundaryMapper = LocalDictationSpeech.TranscriptBoundaryMapper
#endif

protocol TranscriptionEngine: Sendable {
    func transcribe(audioURL: URL) async throws -> FinalTranscript
}

/// An owned slice of the recorder's canonical 16 kHz mono stream.
///
/// `samples` is an Array rather than an audio-buffer view so chunks can safely
/// cross concurrency domains after the realtime render callback returns.
struct AudioChunk: Equatable, Sendable {
    let samples: [Float]
    let sampleRate: Int
    let sequence: Int64
}

struct TranscriptUpdate: Equatable, Sendable {
    let finalized: String
    let volatile: String
}


protocol StreamingTranscriber: Sendable {
    /// Loads and warms the model without starting inference.
    func prepare() async throws

    /// Starts consuming an event-driven sample stream. Implementations must not
    /// capture the microphone themselves or poll while the stream is idle.
    func start(samples: AsyncStream<AudioChunk>) async throws -> AsyncStream<TranscriptUpdate>

    /// Drains a sample stream that its producer has already finished, flushes
    /// decoder state, and returns the authoritative final transcript.
    func finish() async throws -> FinalTranscript

    /// Stops in-flight work and releases session state while retaining prepared
    /// model warmth for a later recording.
    func cancel() async
}

enum StreamingTranscriberError: Error, Equatable, LocalizedError, Sendable {
    case notPrepared
    case alreadyRunning
    case noActiveSession
    case unsupportedSampleRate(expected: Int, actual: Int)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return "The streaming transcription model has not been prepared"
        case .alreadyRunning:
            return "A streaming transcription session is already running"
        case .noActiveSession:
            return "There is no active streaming transcription session"
        case .unsupportedSampleRate(let expected, let actual):
            return "Expected \(expected) Hz audio chunks, received \(actual) Hz"
        case .inferenceFailed(let message):
            return "Streaming transcription failed: \(message)"
        }
    }
}

/// Applies streaming updates without ever appending volatile text to the
/// finalized buffer. Each update replaces both visible ranges atomically.
struct TranscriptBuffer: Equatable, Sendable {
    private(set) var finalized = ""
    private(set) var volatile = ""

    var text: String {
        Self.join(finalized, volatile)
    }

    mutating func apply(_ update: TranscriptUpdate) {
        finalized = update.finalized
        volatile = update.volatile
    }

    mutating func commit(_ transcript: FinalTranscript) {
        finalized = transcript.text
        volatile = ""
    }

    private static func join(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        return "\(left) \(right)"
    }
}
