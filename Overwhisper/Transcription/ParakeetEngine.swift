import Foundation
#if canImport(LocalDictationSpeech)
import LocalDictationSpeech
#endif

/// Adapts the reusable production Parakeet engine to the app's live
/// `AppState` configuration without moving application state into the speech
/// layer.
actor ParakeetEngine: TranscriptionEngine {
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
        let language = await appState.language
        return try await transcribe(
            audioURL: audioURL,
            configuration: SpeechEngineConfiguration(language: language)
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
        AppLogger.transcription.debug("Local Parakeet transcription completed")
        return result
    }
}
