import Combine
import Foundation

enum EngineLifecyclePhase: String, Codable, Equatable, Sendable {
    case idle
    case checking
    case downloading
    case validating
    case preparing
    case ready
    case repairing
    case unavailable
    case failed
}

struct EngineStatus: Equatable, Sendable {
    let selection: ASRSelection
    let phase: EngineLifecyclePhase
    let preparationGeneration: UInt64
    let ownedPath: String?
    let progress: Double?
    let lastError: String?

    static func idle(selection: ASRSelection) -> EngineStatus {
        EngineStatus(
            selection: selection,
            phase: .idle,
            preparationGeneration: 0,
            ownedPath: nil,
            progress: nil,
            lastError: nil
        )
    }
}

struct PreparedEngineRuntime: Sendable {
    let selection: ASRSelection
    let engine: any TranscriptionEngine
    let installation: ModelInstallation
}

struct StagedEngineRuntime: Sendable {
    let engine: any TranscriptionEngine
    let payloadRelativePath: String
}

@MainActor
protocol EngineLifecycleBackend: AnyObject {
    func load(
        selection: ASRSelection,
        installation: ModelInstallation
    ) async throws -> any TranscriptionEngine

    func installAndLoad(
        selection: ASRSelection,
        stagingDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StagedEngineRuntime
}

enum EngineCoordinatorError: LocalizedError, Equatable {
    case stalePreparation
    case unavailable(ASRSelection, String)
    case repairFailed(ASRSelection, String)

    var errorDescription: String? {
        switch self {
        case .stalePreparation:
            return "A newer speech-engine preparation replaced this one"
        case .unavailable(let selection, let message):
            return "\(selection.displayName) is unavailable: \(message)"
        case .repairFailed(let selection, let message):
            return "\(selection.displayName) could not be repaired: \(message)"
        }
    }
}

/// Serializes model preparation and makes stale async completions harmless.
/// Every lifecycle mutation is keyed to `preparationGeneration`; a cancelled
/// or superseded preparation may clean only its own staging directory.
@MainActor
final class EngineCoordinator: ObservableObject {
    @Published private(set) var status: EngineStatus

    private let store: OwnedModelStore
    private let backend: any EngineLifecycleBackend
    private var preparationGeneration: UInt64 = 0
    private var runtime: PreparedEngineRuntime?

    init(
        initialSelection: ASRSelection,
        store: OwnedModelStore,
        backend: any EngineLifecycleBackend
    ) {
        self.store = store
        self.backend = backend
        status = .idle(selection: initialSelection)
    }

    func prepare(selection: ASRSelection) async throws -> PreparedEngineRuntime {
        let generation = nextGeneration()
        runtime = nil
        publish(
            selection: selection,
            phase: .checking,
            generation: generation
        )

        do {
            if let installation = try await inspectOrQuarantine(
                selection: selection,
                generation: generation
            ) {
                do {
                    publish(
                        selection: selection,
                        phase: .validating,
                        generation: generation,
                        ownedPath: installation.currentDirectory.path
                    )
                    let engine = try await backend.load(
                        selection: selection,
                        installation: installation
                    )
                    try ensureCurrent(generation)
                    let prepared = PreparedEngineRuntime(
                        selection: selection,
                        engine: engine,
                        installation: installation
                    )
                    runtime = prepared
                    publishReady(prepared, generation: generation)
                    return prepared
                } catch is CancellationError {
                    throw CancellationError()
                } catch EngineCoordinatorError.stalePreparation {
                    throw EngineCoordinatorError.stalePreparation
                } catch {
                    try ensureCurrent(generation)
                    publish(
                        selection: selection,
                        phase: .repairing,
                        generation: generation,
                        ownedPath: installation.currentDirectory.path,
                        lastError: error.localizedDescription
                    )
                    _ = try await store.quarantineCurrent(
                        for: selection,
                        reason: "load-failed"
                    )
                }
            }

            let prepared = try await install(
                selection: selection,
                generation: generation,
                attempts: 2
            )
            runtime = prepared
            publishReady(prepared, generation: generation)
            return prepared
        } catch is CancellationError {
            if generation == preparationGeneration {
                publish(
                    selection: selection,
                    phase: .idle,
                    generation: generation
                )
            }
            throw CancellationError()
        } catch EngineCoordinatorError.stalePreparation {
            throw EngineCoordinatorError.stalePreparation
        } catch {
            if generation == preparationGeneration {
                runtime = nil
                publish(
                    selection: selection,
                    phase: .failed,
                    generation: generation,
                    lastError: error.localizedDescription
                )
            }
            throw EngineCoordinatorError.repairFailed(
                selection,
                error.localizedDescription
            )
        }
    }

    func verify(selection: ASRSelection) async throws -> PreparedEngineRuntime {
        let generation = nextGeneration()
        runtime = nil
        publish(selection: selection, phase: .validating, generation: generation)
        do {
            guard let installation = try await store.currentInstallation(for: selection) else {
                throw EngineCoordinatorError.unavailable(
                    selection,
                    "No validated Local Dictation installation exists"
                )
            }
            let engine = try await backend.load(
                selection: selection,
                installation: installation
            )
            try ensureCurrent(generation)
            let prepared = PreparedEngineRuntime(
                selection: selection,
                engine: engine,
                installation: installation
            )
            runtime = prepared
            publishReady(prepared, generation: generation)
            return prepared
        } catch {
            if generation == preparationGeneration {
                publish(
                    selection: selection,
                    phase: .failed,
                    generation: generation,
                    lastError: error.localizedDescription
                )
            }
            throw error
        }
    }

    func repair(selection: ASRSelection) async throws -> PreparedEngineRuntime {
        cancelPreparation(selection: selection)
        _ = try await store.resetInstallation(for: selection)
        return try await prepare(selection: selection)
    }

    /// Wake checks ownership/manifest health. It deliberately does not reload a
    /// warm model merely because the machine resumed from sleep.
    func healthCheck(selection: ASRSelection) async -> Bool {
        guard runtime?.selection == selection,
              status.phase == .ready
        else { return false }
        do {
            return try await store.currentInstallation(for: selection) != nil
        } catch {
            publish(
                selection: selection,
                phase: .failed,
                generation: preparationGeneration,
                lastError: error.localizedDescription
            )
            return false
        }
    }

    func cancelPreparation(selection: ASRSelection? = nil) {
        preparationGeneration &+= 1
        runtime = nil
        publish(
            selection: selection ?? status.selection,
            phase: .idle,
            generation: preparationGeneration
        )
    }

    private func inspectOrQuarantine(
        selection: ASRSelection,
        generation: UInt64
    ) async throws -> ModelInstallation? {
        do {
            let installation = try await store.currentInstallation(for: selection)
            try ensureCurrent(generation)
            return installation
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ensureCurrent(generation)
            publish(
                selection: selection,
                phase: .repairing,
                generation: generation,
                lastError: error.localizedDescription
            )
            _ = try await store.quarantineCurrent(
                for: selection,
                reason: "manifest-invalid"
            )
            return nil
        }
    }

    private func install(
        selection: ASRSelection,
        generation: UInt64,
        attempts: Int
    ) async throws -> PreparedEngineRuntime {
        var lastError: Error?
        for attempt in 1...attempts {
            try ensureCurrent(generation)
            let staging = try await store.makeStagingDirectory(for: selection)
            do {
                publish(
                    selection: selection,
                    phase: attempt == 1 ? .downloading : .repairing,
                    generation: generation,
                    progress: 0,
                    lastError: lastError?.localizedDescription
                )
                let staged = try await backend.installAndLoad(
                    selection: selection,
                    stagingDirectory: staging,
                    progress: progressHandler(
                        selection: selection,
                        generation: generation
                    )
                )
                try ensureCurrent(generation)
                publish(
                    selection: selection,
                    phase: .validating,
                    generation: generation,
                    progress: 1
                )
                let installation = try await store.promote(
                    stagingDirectory: staging,
                    for: selection,
                    payloadRelativePath: staged.payloadRelativePath,
                    sourceHost: selection.sourceHost
                )
                try ensureCurrent(generation)
                return PreparedEngineRuntime(
                    selection: selection,
                    engine: staged.engine,
                    installation: installation
                )
            } catch {
                await store.discardStaging(staging)
                if error is CancellationError { throw CancellationError() }
                if let coordinatorError = error as? EngineCoordinatorError,
                   coordinatorError == .stalePreparation {
                    throw coordinatorError
                }
                lastError = error
            }
        }
        throw lastError ?? EngineCoordinatorError.unavailable(
            selection,
            "Preparation failed without an error"
        )
    }

    private func progressHandler(
        selection: ASRSelection,
        generation: UInt64
    ) -> @Sendable (Double) -> Void {
        { [weak self] progress in
            Task { @MainActor in
                guard let self,
                      generation == self.preparationGeneration,
                      [.downloading, .repairing, .preparing].contains(self.status.phase)
                else { return }
                let normalized = min(1, max(0, progress))
                self.publish(
                    selection: selection,
                    phase: normalized >= 1 ? .preparing : .downloading,
                    generation: generation,
                    progress: normalized
                )
            }
        }
    }

    private func nextGeneration() -> UInt64 {
        preparationGeneration &+= 1
        return preparationGeneration
    }

    private func ensureCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == preparationGeneration else {
            throw EngineCoordinatorError.stalePreparation
        }
    }

    private func publishReady(
        _ prepared: PreparedEngineRuntime,
        generation: UInt64
    ) {
        publish(
            selection: prepared.selection,
            phase: .ready,
            generation: generation,
            ownedPath: prepared.installation.currentDirectory.path,
            progress: 1
        )
    }

    private func publish(
        selection: ASRSelection,
        phase: EngineLifecyclePhase,
        generation: UInt64,
        ownedPath: String? = nil,
        progress: Double? = nil,
        lastError: String? = nil
    ) {
        let retainedOwnedPath = status.selection == selection
            && [.checking, .validating, .ready].contains(phase)
            ? status.ownedPath
            : nil
        status = EngineStatus(
            selection: selection,
            phase: phase,
            preparationGeneration: generation,
            ownedPath: ownedPath ?? retainedOwnedPath,
            progress: progress,
            lastError: lastError
        )
    }
}
