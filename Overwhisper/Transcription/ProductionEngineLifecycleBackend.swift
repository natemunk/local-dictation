import Foundation
#if canImport(LocalDictationSpeech)
import LocalDictationSpeech
#endif

/// App-facing adapter over the reusable production loader. The coordinator
/// continues to own UI lifecycle, repair, and generation semantics; only model
/// loading and authoritative final inference are shared with the corpus runner.
@MainActor
final class ProductionEngineLifecycleBackend: EngineLifecycleBackend {
    private let appState: AppState
    private let loader: ProductionSpeechEngineLoader

    init(appState: AppState) {
        self.appState = appState
        loader = ProductionSpeechEngineLoader()
    }

    init(
        appState: AppState,
        loader: ProductionSpeechEngineLoader
    ) {
        self.appState = appState
        self.loader = loader
    }

    func load(
        selection: ASRSelection,
        installation: ModelInstallation
    ) async throws -> any TranscriptionEngine {
        let engine = try await loader.load(
            selection: selection,
            installation: installation,
            networkPolicy: .offlineOnly
        )
        return adapt(engine, selection: selection)
    }

    func installAndLoad(
        selection: ASRSelection,
        stagingDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StagedEngineRuntime {
        let staged = try await loader.installAndLoad(
            selection: selection,
            stagingDirectory: stagingDirectory,
            progress: progress
        )
        return StagedEngineRuntime(
            engine: adapt(staged.engine, selection: selection),
            payloadRelativePath: staged.payloadRelativePath
        )
    }

    private func adapt(
        _ engine: any ProductionFinalSpeechEngine,
        selection: ASRSelection
    ) -> any TranscriptionEngine {
        switch selection {
        case .parakeetV2, .parakeetV3:
            return ParakeetEngine(productionEngine: engine, appState: appState)
        case .whisperSmallEn, .whisperLargeV3Turbo:
            return WhisperKitEngine(productionEngine: engine, appState: appState)
        }
    }
}
