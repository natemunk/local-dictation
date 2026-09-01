import Foundation
import LocalDictationSpeech

@MainActor
protocol CorpusSpeechEngineLoading: AnyObject {
    func load(
        selection: ASRSelection,
        installation: ModelInstallation,
        networkPolicy: SpeechModelNetworkPolicy
    ) async throws -> any ProductionFinalSpeechEngine

    func installAndLoad(
        selection: ASRSelection,
        stagingDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StagedProductionSpeechEngine
}

extension ProductionSpeechEngineLoader: CorpusSpeechEngineLoading {}

@MainActor
protocol CorpusEngineRuntimeProviding: AnyObject {
    func runtime(
        for selection: ASRSelection,
        allowModelPreparation: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CorpusEngineRuntime
}

@MainActor
final class ProductionCorpusEngineRuntimeProvider: CorpusEngineRuntimeProviding {
    private let store: OwnedModelStore
    private let loader: any CorpusSpeechEngineLoading

    init(store: OwnedModelStore) {
        self.store = store
        loader = ProductionSpeechEngineLoader()
    }

    init(
        store: OwnedModelStore,
        loader: any CorpusSpeechEngineLoading
    ) {
        self.store = store
        self.loader = loader
    }

    func runtime(
        for selection: ASRSelection,
        allowModelPreparation: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CorpusEngineRuntime {
        let start = ContinuousClock.now
        do {
            if let installation = try await store.currentInstallation(for: selection) {
                do {
                    let engine = try await loader.load(
                        selection: selection,
                        installation: installation,
                        networkPolicy: .offlineOnly
                    )
                    return CorpusEngineRuntime(
                        selection: selection,
                        engine: engine,
                        installation: installation,
                        preparationPerformed: false,
                        loadSeconds: seconds(since: start)
                    )
                } catch {
                    guard allowModelPreparation else {
                        throw CorpusRunnerFailure.modelUnavailable(
                            selection,
                            "owned installation failed offline validation/load: \(error.localizedDescription)"
                        )
                    }
                    _ = try await store.quarantineCurrent(
                        for: selection,
                        reason: "corpus-runner-load-failed"
                    )
                }
            } else if !allowModelPreparation {
                throw CorpusRunnerFailure.modelUnavailable(
                    selection,
                    "no owned installation exists; rerun with --allow-model-preparation to permit a download"
                )
            }
        } catch let error as CorpusRunnerFailure {
            throw error
        } catch {
            guard allowModelPreparation else {
                throw CorpusRunnerFailure.modelUnavailable(
                    selection,
                    "owned installation inspection failed: \(error.localizedDescription)"
                )
            }
            _ = try await store.quarantineCurrent(
                for: selection,
                reason: "corpus-runner-manifest-invalid"
            )
        }

        return try await prepare(
            selection: selection,
            start: start,
            progress: progress
        )
    }

    private func prepare(
        selection: ASRSelection,
        start: ContinuousClock.Instant,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CorpusEngineRuntime {
        let staging = try await store.makeStagingDirectory(for: selection)
        do {
            let staged = try await loader.installAndLoad(
                selection: selection,
                stagingDirectory: staging,
                progress: progress
            )
            let installation = try await store.promote(
                stagingDirectory: staging,
                for: selection,
                payloadRelativePath: staged.payloadRelativePath,
                sourceHost: selection.sourceHost
            )
            return CorpusEngineRuntime(
                selection: selection,
                engine: staged.engine,
                installation: installation,
                preparationPerformed: true,
                loadSeconds: seconds(since: start)
            )
        } catch {
            await store.discardStaging(staging)
            throw CorpusRunnerFailure.modelUnavailable(
                selection,
                "explicit model preparation failed: \(error.localizedDescription)"
            )
        }
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1.0e18
    }
}
