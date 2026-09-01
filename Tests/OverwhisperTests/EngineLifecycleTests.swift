import Foundation
import Testing
@testable import LocalDictation

@Suite("Engine lifecycle", .serialized)
@MainActor
struct EngineLifecycleTests {
    @Test("model preparation phases explain long-running first setup honestly")
    func preparationPresentation() {
        #expect(EngineLifecyclePhase.downloading.isPreparationWork)
        #expect(EngineLifecyclePhase.preparing.isPreparationWork)
        #expect(!EngineLifecyclePhase.ready.isPreparationWork)
        #expect(EngineLifecyclePhase.downloading.userFacingTitle.contains("Downloading"))
        #expect(EngineLifecyclePhase.preparing.userFacingTitle.contains("Optimizing"))
        #expect(EngineLifecyclePhase.preparing.userFacingDetail?.contains("several minutes") == true)
    }

    @Test("duration-aware Whisper deadline is bounded and monotonic")
    func whisperDeadlinePolicy() {
        #expect(ASRDeadlinePolicy.whisperTimeoutSeconds(audioDuration: 0) == 20)
        #expect(ASRDeadlinePolicy.whisperTimeoutSeconds(audioDuration: 60) == 30)
        #expect(ASRDeadlinePolicy.whisperTimeoutSeconds(audioDuration: 900) == 210)
        #expect(ASRDeadlinePolicy.whisperTimeoutSeconds(audioDuration: .infinity) == 20)
    }

    @Test("EOU recovery is preview-only and never executes commands")
    func eouRecoveryPolicy() throws {
        #expect(ASRFinalizationPolicy.recoverFromEOU("   ") == nil)
        let fallback = try #require(
            ASRFinalizationPolicy.recoverFromEOU("scratch that ship it")
        )
        #expect(fallback.source == .eouPreviewFallback)
        #expect(fallback.delivery == .previewOnly)
        #expect(!fallback.commandsAllowed)
        #expect(fallback.transcript.text == "scratch that ship it")

        let authoritative = ASRFinalizationPolicy.authoritative(
            FinalTranscript(text: "ship it", language: "en")
        )
        #expect(authoritative.source == .authoritativeBatch)
        #expect(authoritative.delivery == .requestedDelivery)
        #expect(authoritative.commandsAllowed)
    }

    @Test("missing installation is downloaded validated promoted and ready")
    func preparesMissingInstallation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OwnedModelStore(rootURL: root)
        let backend = FakeEngineLifecycleBackend()
        let coordinator = EngineCoordinator(
            initialSelection: .parakeetV2,
            store: store,
            backend: backend
        )

        let runtime = try await coordinator.prepare(selection: .parakeetV2)
        await Task.yield()

        #expect(runtime.selection == .parakeetV2)
        #expect(coordinator.status.phase == .ready)
        #expect(backend.installCount == 1)
        #expect(backend.loadCount == 0)
        #expect(try await store.currentInstallation(for: .parakeetV2) != nil)
    }

    @Test("an invalid current runtime is quarantined before one fresh install")
    func repairsFailedCurrentLoad() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OwnedModelStore(rootURL: root)
        _ = try await makeInstallation(for: .parakeetV2, store: store, marker: "old")
        let backend = FakeEngineLifecycleBackend(loadFailuresRemaining: 1)
        let coordinator = EngineCoordinator(
            initialSelection: .parakeetV2,
            store: store,
            backend: backend
        )

        _ = try await coordinator.prepare(selection: .parakeetV2)

        #expect(coordinator.status.phase == .ready)
        #expect(backend.loadCount == 1)
        #expect(backend.installCount == 1)
        let quarantine = await store.quarantineRoot(for: .parakeetV2)
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: quarantine,
            includingPropertiesForKeys: nil
        )
        #expect(quarantined.count == 1)
    }

    @Test("a fresh install is retried once and then fails honestly")
    func retriesFreshInstallOnlyOnce() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OwnedModelStore(rootURL: root)
        let backend = FakeEngineLifecycleBackend(installFailuresRemaining: 2)
        let coordinator = EngineCoordinator(
            initialSelection: .whisperSmallEn,
            store: store,
            backend: backend
        )

        await #expect(throws: EngineCoordinatorError.self) {
            _ = try await coordinator.prepare(selection: .whisperSmallEn)
        }

        #expect(backend.installCount == 2)
        #expect(coordinator.status.phase == .failed)
        #expect(try await store.currentInstallation(for: .whisperSmallEn) == nil)
    }

    @Test("verify never downloads a missing model")
    func verifyDoesNotDownload() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OwnedModelStore(rootURL: root)
        let backend = FakeEngineLifecycleBackend()
        let coordinator = EngineCoordinator(
            initialSelection: .parakeetV3,
            store: store,
            backend: backend
        )

        await #expect(throws: EngineCoordinatorError.self) {
            _ = try await coordinator.verify(selection: .parakeetV3)
        }
        #expect(backend.installCount == 0)
        #expect(backend.loadCount == 0)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "local-dictation-engine-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makeInstallation(
        for selection: ASRSelection,
        store: OwnedModelStore,
        marker: String
    ) async throws -> ModelInstallation {
        let staging = try await store.makeStagingDirectory(for: selection)
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: payload.appendingPathComponent("marker"))
        return try await store.promote(
            stagingDirectory: staging,
            for: selection,
            payloadRelativePath: "payload",
            sourceHost: selection.sourceHost
        )
    }
}

@MainActor
private final class FakeEngineLifecycleBackend: EngineLifecycleBackend {
    private(set) var installCount = 0
    private(set) var loadCount = 0
    private var installFailuresRemaining: Int
    private var loadFailuresRemaining: Int

    init(
        installFailuresRemaining: Int = 0,
        loadFailuresRemaining: Int = 0
    ) {
        self.installFailuresRemaining = installFailuresRemaining
        self.loadFailuresRemaining = loadFailuresRemaining
    }

    func load(
        selection: ASRSelection,
        installation: ModelInstallation
    ) async throws -> any TranscriptionEngine {
        loadCount += 1
        if loadFailuresRemaining > 0 {
            loadFailuresRemaining -= 1
            throw FakeEngineError.expectedFailure
        }
        return FakePreparedEngine(selection: selection)
    }

    func installAndLoad(
        selection: ASRSelection,
        stagingDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StagedEngineRuntime {
        installCount += 1
        if installFailuresRemaining > 0 {
            installFailuresRemaining -= 1
            throw FakeEngineError.expectedFailure
        }
        let payload = stagingDirectory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data(selection.rawValue.utf8).write(to: payload.appendingPathComponent("model"))
        progress(1)
        return StagedEngineRuntime(
            engine: FakePreparedEngine(selection: selection),
            payloadRelativePath: "payload"
        )
    }
}

private actor FakePreparedEngine: TranscriptionEngine {
    let selection: ASRSelection

    init(selection: ASRSelection) {
        self.selection = selection
    }

    func transcribe(audioURL: URL) async throws -> FinalTranscript {
        FinalTranscript(text: selection.rawValue, language: "en")
    }
}

private enum FakeEngineError: Error {
    case expectedFailure
}
