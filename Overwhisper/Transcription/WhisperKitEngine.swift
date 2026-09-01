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
        AppLogger.transcription.debug("Transcribing a local temporary recording")
        let vocabulary = await appState.customVocabulary
        let result = try await productionEngine.transcribe(
            audioURL: audioURL,
            configuration: SpeechEngineConfiguration(
                language: "en",
                customVocabulary: vocabulary
            )
        )
        AppLogger.transcription.debug("Local WhisperKit transcription completed")
        return result
    }
}
