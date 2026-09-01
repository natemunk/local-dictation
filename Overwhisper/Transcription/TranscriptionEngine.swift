import Foundation

protocol TranscriptionEngine: Sendable {
    func transcribe(audioURL: URL) async throws -> FinalTranscript
}

enum TranscriptBoundarySource: Equatable, Sendable {
    case pause
    case segment
}

/// A boundary before a phrase in `FinalTranscript.text`.
///
/// UTF-8 offsets are stable across concurrency and persistence boundaries. The
/// transcript initializer keeps only offsets that land on Swift `Character`
/// boundaries after surrounding whitespace is trimmed.
struct TranscriptBoundary: Equatable, Sendable {
    let utf8Offset: Int
    let source: TranscriptBoundarySource
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

struct FinalTranscript: Equatable, Sendable {
    let text: String
    let language: String?
    let boundaries: [TranscriptBoundary]

    init(
        text rawText: String,
        language: String? = nil,
        boundaries rawBoundaries: [TranscriptBoundary] = []
    ) {
        let trimmed = Self.trimmedText(rawText)
        text = trimmed.text
        self.language = language
        boundaries = Self.validatedBoundaries(
            rawBoundaries,
            removingLeadingUTF8Bytes: trimmed.leadingUTF8Bytes,
            in: trimmed.text
        )
    }

    private static func trimmedText(_ text: String) -> (text: String, leadingUTF8Bytes: Int) {
        var lowerBound = text.startIndex
        while lowerBound < text.endIndex, text[lowerBound].isWhitespace {
            lowerBound = text.index(after: lowerBound)
        }

        var upperBound = text.endIndex
        while upperBound > lowerBound {
            let previous = text.index(before: upperBound)
            guard text[previous].isWhitespace else { break }
            upperBound = previous
        }

        return (
            String(text[lowerBound..<upperBound]),
            text[..<lowerBound].utf8.count
        )
    }

    private static func validatedBoundaries(
        _ boundaries: [TranscriptBoundary],
        removingLeadingUTF8Bytes leadingUTF8Bytes: Int,
        in text: String
    ) -> [TranscriptBoundary] {
        var seenOffsets = Set<Int>()
        return boundaries
            .compactMap { boundary -> TranscriptBoundary? in
                let offset = boundary.utf8Offset - leadingUTF8Bytes
                guard offset > 0,
                      offset < text.utf8.count,
                      isCharacterBoundary(offset, in: text),
                      seenOffsets.insert(offset).inserted
                else { return nil }
                return TranscriptBoundary(utf8Offset: offset, source: boundary.source)
            }
            .sorted { $0.utf8Offset < $1.utf8Offset }
    }

    private static func isCharacterBoundary(_ utf8Offset: Int, in text: String) -> Bool {
        let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Offset)
        return String.Index(utf8Index, within: text) != nil
    }
}

struct TimedTranscriptFragment: Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum TranscriptBoundaryMapper {
    /// Long enough to avoid treating ordinary inter-token spacing as a phrase
    /// boundary, while retaining a deliberate spoken pause.
    static let minimumPauseDuration: TimeInterval = 0.45

    static func pauseBoundaries(
        in transcript: String,
        fragments: [TimedTranscriptFragment]
    ) -> [TranscriptBoundary] {
        let fragments = fragments.filter { !$0.text.isEmpty }
        guard fragments.count > 1 else { return [] }

        var boundaryFragmentIndices: [Int] = []
        for index in fragments.indices.dropFirst() {
            let previous = fragments[fragments.index(before: index)]
            let current = fragments[index]
            guard hasValidTiming(previous),
                  hasValidTiming(current),
                  current.startTime - previous.endTime >= minimumPauseDuration
            else { continue }
            boundaryFragmentIndices.append(index)
        }
        return mappedBoundaries(
            in: transcript,
            fragments: fragments,
            boundaryFragmentIndices: boundaryFragmentIndices,
            source: .pause
        )
    }

    static func segmentBoundaries(
        in transcript: String,
        fragments: [TimedTranscriptFragment]
    ) -> [TranscriptBoundary] {
        let fragments = fragments.filter { !$0.text.isEmpty }
        guard fragments.count > 1 else { return [] }

        var boundaryFragmentIndices: [Int] = []
        for index in fragments.indices.dropFirst() {
            let previous = fragments[fragments.index(before: index)]
            let current = fragments[index]
            guard hasValidTiming(previous),
                  hasValidTiming(current),
                  current.startTime >= previous.startTime
            else { continue }
            boundaryFragmentIndices.append(index)
        }
        return mappedBoundaries(
            in: transcript,
            fragments: fragments,
            boundaryFragmentIndices: boundaryFragmentIndices,
            source: .segment
        )
    }

    private static func mappedBoundaries(
        in transcript: String,
        fragments: [TimedTranscriptFragment],
        boundaryFragmentIndices: [Int],
        source: TranscriptBoundarySource
    ) -> [TranscriptBoundary] {
        var reconstructed = ""
        var rawBoundaries: [TranscriptBoundary] = []
        let boundaryIndices = Set(boundaryFragmentIndices)

        for (index, fragment) in fragments.enumerated() {
            if boundaryIndices.contains(index) {
                rawBoundaries.append(
                    TranscriptBoundary(utf8Offset: reconstructed.utf8.count, source: source)
                )
            }
            reconstructed.append(fragment.text)
        }

        let mapped = FinalTranscript(
            text: reconstructed,
            boundaries: rawBoundaries
        )
        let reference = FinalTranscript(text: transcript)
        guard mapped.text == reference.text else { return [] }
        return mapped.boundaries
    }

    private static func hasValidTiming(_ fragment: TimedTranscriptFragment) -> Bool {
        fragment.startTime.isFinite
            && fragment.endTime.isFinite
            && fragment.startTime >= 0
            && fragment.endTime >= fragment.startTime
    }
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
