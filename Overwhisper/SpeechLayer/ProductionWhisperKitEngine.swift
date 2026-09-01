@preconcurrency import AVFoundation
import Foundation
@preconcurrency import WhisperKit

public actor ProductionWhisperKitEngine: ProductionFinalSpeechEngine {
    public nonisolated let selection: ASRSelection

    private let whisperKit: WhisperKit

    public init(selection: ASRSelection, whisperKit: WhisperKit) {
        self.selection = selection
        self.whisperKit = whisperKit
    }

    public func transcribe(
        audioURL: URL,
        configuration: SpeechEngineConfiguration
    ) async throws -> FinalTranscript {
        try Task.checkCancellation()

        var promptTokens: [Int]?
        if !configuration.customVocabulary.isEmpty, let tokenizer = whisperKit.tokenizer {
            let promptText = " " + configuration.customVocabulary.trimmingCharacters(in: .whitespaces)
            promptTokens = tokenizer.encode(text: promptText)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }

        let decodingOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            temperatureFallbackCount: 5,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            clipTimestamps: [],
            promptTokens: promptTokens
        )

        let deadlineSeconds = ASRDeadlinePolicy.whisperTimeoutSeconds(
            audioDuration: Self.audioDuration(at: audioURL)
        )
        let transcript = try await withThrowingTaskGroup(of: FinalTranscript.self) { group in
            group.addTask {
                let results = try await self.whisperKit.transcribe(
                    audioPath: audioURL.path,
                    decodeOptions: decodingOptions
                )
                try Task.checkCancellation()
                return Self.finalTranscript(from: results)
            }

            group.addTask {
                try await Task.sleep(for: .seconds(deadlineSeconds))
                throw WhisperKitError.timeout(seconds: deadlineSeconds)
            }

            guard let result = try await group.next() else {
                throw WhisperKitError.transcriptionFailed("No result")
            }
            group.cancelAll()
            return result
        }

        try Task.checkCancellation()
        return transcript
    }

    private static func audioDuration(at url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0
        else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func finalTranscript(from results: [TranscriptionResult]) -> FinalTranscript {
        var text = ""
        var language: String?
        var boundaries: [TranscriptBoundary] = []

        for result in results {
            let normalized = FinalTranscript(text: result.text, language: result.language)
            guard !normalized.text.isEmpty else { continue }

            let fragments = result.segments.map {
                TimedTranscriptFragment(
                    text: $0.text,
                    startTime: TimeInterval($0.start),
                    endTime: TimeInterval($0.end)
                )
            }
            let component = FinalTranscript(
                text: normalized.text,
                language: normalized.language,
                boundaries: TranscriptBoundaryMapper.segmentBoundaries(
                    in: normalized.text,
                    fragments: fragments
                )
            )

            let separator = text.isEmpty ? "" : " "
            let componentOffset = text.utf8.count + separator.utf8.count
            text.append(separator)
            text.append(component.text)
            boundaries.append(contentsOf: component.boundaries.map {
                TranscriptBoundary(
                    utf8Offset: componentOffset + $0.utf8Offset,
                    source: $0.source
                )
            })
            if language == nil {
                language = component.language
            }
        }

        return FinalTranscript(text: text, language: language, boundaries: boundaries)
    }
}

public enum ASRDeadlinePolicy {
    /// Allow startup headroom plus 25% of audio duration, with a hard bound for
    /// the app's 15-minute recording cap.
    public static func whisperTimeoutSeconds(audioDuration: TimeInterval) -> TimeInterval {
        let safeDuration = audioDuration.isFinite ? max(0, audioDuration) : 0
        return min(210, max(20, 15 + safeDuration * 0.25))
    }
}

public enum WhisperKitError: LocalizedError {
    case notInitialized
    case modelNotFound
    case transcriptionFailed(String)
    case timeout(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit is not initialized"
        case .modelNotFound:
            return "Whisper model not found"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .timeout(let seconds):
            return "Transcription timed out after \(Int(seconds.rounded())) seconds"
        }
    }
}
