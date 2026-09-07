import Foundation
#if canImport(LocalDictationSpeech)
import LocalDictationSpeech

typealias ASRDeadlinePolicy = LocalDictationSpeech.ASRDeadlinePolicy
#endif

/// Adapts the reusable production WhisperKit engine to the app's live
/// vocabulary while keeping the authoritative decoding implementation shared
/// with the corpus runner.
actor WhisperKitEngine: TranscriptionEngine {
    private let productionEngine: any ProductionFinalSpeechEngine
    private let appState: AppState

    init(
        productionEngine: any ProductionFinalSpeechEngine,
        appState: AppState
    ) {
        self.productionEngine = productionEngine
        self.appState = appState
    }

    func transcribe(audioURL: URL) async throws -> FinalTranscript {
        let vocabulary = await appState.customVocabulary
        return try await transcribe(
            audioURL: audioURL,
            configuration: SpeechEngineConfiguration(
                language: "en",
                customVocabulary: vocabulary
            )
        )
    }

    func transcribe(
        audioURL: URL,
        configuration: SpeechEngineConfiguration
    ) async throws -> FinalTranscript {
        AppLogger.transcription.debug("Transcribing a local temporary recording")
        let result = try await productionEngine.transcribe(
            audioURL: audioURL,
            configuration: configuration
        )
        AppLogger.transcription.debug("Local WhisperKit transcription completed")
        return result
    }
}
