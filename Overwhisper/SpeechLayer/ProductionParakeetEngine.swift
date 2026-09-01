import FluidAudio
import Foundation

public actor ProductionParakeetEngine: ProductionFinalSpeechEngine {
    public nonisolated let selection: ASRSelection

    private let asrManager: AsrManager

    public init(selection: ASRSelection, asrManager: AsrManager) {
        self.selection = selection
        self.asrManager = asrManager
    }

    public func transcribe(
        audioURL: URL,
        configuration: SpeechEngineConfiguration
    ) async throws -> FinalTranscript {
        try Task.checkCancellation()
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let language = configuration.language == "auto"
            ? nil
            : Language(rawValue: configuration.language)
        let result = try await asrManager.transcribe(
            audioURL,
            decoderState: &decoderState,
            language: language
        )
        try Task.checkCancellation()

        let transcript = FinalTranscript(text: result.text, language: language?.rawValue)
        let fragments = result.tokenTimings?.map {
            TimedTranscriptFragment(
                text: $0.token,
                startTime: $0.startTime,
                endTime: $0.endTime
            )
        } ?? []
        let boundaries = TranscriptBoundaryMapper.pauseBoundaries(
            in: transcript.text,
            fragments: fragments
        )
        return FinalTranscript(
            text: transcript.text,
            language: transcript.language,
            boundaries: boundaries
        )
    }
}

public enum ParakeetError: LocalizedError {
    case installationInvalid(String)
    case initializationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .installationInvalid(let message):
            return "Parakeet model installation is invalid: \(message)"
        case .initializationFailed(let message):
            return "Parakeet initialization failed: \(message)"
        }
    }
}
