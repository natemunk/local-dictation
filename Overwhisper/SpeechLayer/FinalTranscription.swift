import Foundation

public struct SpeechEngineConfiguration: Equatable, Sendable {
    public let language: String
    public let customVocabulary: String

    public init(language: String = "en", customVocabulary: String = "") {
        self.language = language
        self.customVocabulary = customVocabulary
    }
}

/// The authoritative, finish-time speech engine used by both the app and the
/// production corpus runner. Live preview/EOU engines intentionally do not
/// conform to this protocol.
public protocol ProductionFinalSpeechEngine: Sendable {
    var selection: ASRSelection { get }

    func transcribe(
        audioURL: URL,
        configuration: SpeechEngineConfiguration
    ) async throws -> FinalTranscript
}

public enum TranscriptBoundarySource: Equatable, Sendable {
    case pause
    case segment
}

/// A boundary before a phrase in `FinalTranscript.text`.
///
/// UTF-8 offsets are stable across concurrency and persistence boundaries. The
/// transcript initializer keeps only offsets that land on Swift `Character`
/// boundaries after surrounding whitespace is trimmed.
public struct TranscriptBoundary: Equatable, Sendable {
    public let utf8Offset: Int
    public let source: TranscriptBoundarySource

    public init(utf8Offset: Int, source: TranscriptBoundarySource) {
        self.utf8Offset = utf8Offset
        self.source = source
    }
}

public struct FinalTranscript: Equatable, Sendable {
    public let text: String
    public let language: String?
    public let boundaries: [TranscriptBoundary]

    public init(
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

public struct TimedTranscriptFragment: Equatable, Sendable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

public enum TranscriptBoundaryMapper {
    /// Long enough to avoid treating ordinary inter-token spacing as a phrase
    /// boundary, while retaining a deliberate spoken pause.
    public static let minimumPauseDuration: TimeInterval = 0.45

    public static func pauseBoundaries(
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

    public static func segmentBoundaries(
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
