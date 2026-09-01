import FluidAudio
import Foundation

actor ParakeetEngine: TranscriptionEngine {
    private let asrManager: AsrManager
    private let appState: AppState

    /// Receives a model that the lifecycle coordinator already validated and
    /// loaded from a Local Dictation-owned installation.
    init(asrManager: AsrManager, appState: AppState) {
        self.asrManager = asrManager
        self.appState = appState
    }

    func transcribe(audioURL: URL) async throws -> FinalTranscript {
        try Task.checkCancellation()
        AppLogger.transcription.debug("Transcribing a local temporary recording")
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let language = await languageHint()
        let result = try await asrManager.transcribe(
            audioURL,
            decoderState: &decoderState,
            language: language
        )
        try Task.checkCancellation()
        AppLogger.transcription.debug("Local Parakeet transcription completed")

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

    private func languageHint() async -> Language? {
        let code = await appState.language
        guard code != "auto" else { return nil }
        return Language(rawValue: code)
    }
}

enum ParakeetError: LocalizedError {
    case installationInvalid(String)
    case initializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .installationInvalid(let message):
            return "Parakeet model installation is invalid: \(message)"
        case .initializationFailed(let message):
            return "Parakeet initialization failed: \(message)"
        }
    }
}
