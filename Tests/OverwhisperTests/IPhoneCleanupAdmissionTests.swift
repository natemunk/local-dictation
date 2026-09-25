import Foundation
import Testing
@testable import LocalDictation

@Suite("iPhone production cleanup admission")
struct IPhoneCleanupAdmissionTests {
    private struct Engine: TranscriptionEngine {
        func transcribe(audioURL: URL) async throws -> FinalTranscript {
            FinalTranscript(text: "Synthetic test result.")
        }
    }
    private struct NeverNeededAdapter: AppleFoundationModelAdapter {
        func availability() -> AppleFoundationModelAvailability { .available }
        func generate(transcript: String, staticRules: String) async throws -> String {
            Issue.record("A busy admission slot must skip the provider")
            return transcript
        }
    }

    @Test(arguments: [false, true])
    func busyCleanupReportsDeterministicWithoutCloudFallback(streamed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try IPhoneStreamWAVWriter(requestID: UUID(), temporaryDirectory: directory)
        _ = try await writer.append(Data(repeating: 0, count: 3_200))
        let audio = try await writer.finish()
        let admission = CleanupAdmissionController()
        let owner = try admission.acquire()
        defer { admission.release(owner) }
        let pipeline = CleanupPipeline(refiner: AppleFoundationRefiner(
            adapter: NeverNeededAdapter(), admission: admission,
            platformSupportsFoundationModels: { true }))
        let result = try await process(streamed: streamed, audio: audio, pipeline: pipeline, directory: directory)
        #expect(result.response.cleanup == .deterministic)
        #expect(result.response.route == .macLocal)
        #expect(result.response.fallbackReason == nil)
        #expect(result.cleanupOutcome == "deterministic_fallback")
        #expect(result.cleanupFallbackReason == "admission_busy")
        #expect(result.response.historyState == .disabled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @Test(arguments: [false, true])
    func desktopPreemptionDrainsCleanupWithoutHoldingASRLease(streamed: Bool) async throws {
        struct DelayedAdapter: AppleFoundationModelAdapter {
            let gate: CancellationIgnoringCleanupGate
            func availability() -> AppleFoundationModelAvailability { .available }
            func generate(transcript: String, staticRules: String) async throws -> String {
                await gate.wait()
                return transcript
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try IPhoneStreamWAVWriter(requestID: UUID(), temporaryDirectory: directory)
        _ = try await writer.append(Data(repeating: 0, count: 3_200))
        let audio = try await writer.finish()
        let admission = CleanupAdmissionController()
        let gate = CancellationIgnoringCleanupGate()
        defer { gate.open() }
        let pipeline = CleanupPipeline(refiner: AppleFoundationRefiner(
            adapter: DelayedAdapter(gate: gate), admission: admission, platformSupportsFoundationModels: { true }))
        let leases = InferenceLeaseCoordinator()
        let lease = try #require(leases.tryBeginRemote())
        let work = Task {
            defer { leases.endRemote(lease) }
            return try await process(streamed: streamed, audio: audio, pipeline: pipeline, directory: directory)
        }
        defer { work.cancel() }
        lease.installCancellation { work.cancel() }
        let preparationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.hasStarted && ContinuousClock.now < preparationDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(gate.hasStarted)
        let cancelledAt = ContinuousClock.now
        leases.beginDesktop()
        do { _ = try await work.value; Issue.record("Remote cleanup must propagate preemption") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(type(of: error))") }
        try await leases.waitForRemoteRelease(timeout: .milliseconds(50))
        #expect(cancelledAt.duration(to: .now) < .milliseconds(250))
        #expect(admission.snapshot().state == .draining)
        leases.endDesktop()
        gate.open()
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while admission.snapshot().state != .idle && ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(admission.snapshot().state == .idle)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    private func process(streamed: Bool, audio: IPhoneStreamedAudio, pipeline: CleanupPipeline,
                         directory: URL) async throws -> IPhoneLocalProcessingResult {
        if streamed {
            return try await AppDelegate.runIPhoneStreamTranscription(
                request: .init(requestID: UUID(), mode: .clean, allowsCloudFallback: true, client: .pwa),
                audio: audio, engine: Engine(), selection: .parakeetV2,
                speechConfiguration: .init(language: "en"), cleanupPipeline: pipeline,
                requestedCleanupBackend: .appleFoundation, cleanupExecutor: CleanupExecutor(),
                deadline: .seconds(2), started: .now, unifiedHistoryStore: nil, historyAuthorization: nil)
        } else {
            return try await AppDelegate.runIPhoneTranscription(
                request: .init(requestID: UUID(), mode: .clean, allowsCloudFallback: true,
                               claimedDurationSeconds: audio.durationSeconds, mediaType: "audio/wav",
                               audio: Data(contentsOf: audio.wavURL)),
                engine: Engine(), selection: .parakeetV2, speechConfiguration: .init(language: "en"),
                cleanupPipeline: pipeline, requestedCleanupBackend: .appleFoundation,
                normalizer: RemoteAudioNormalizer(temporaryDirectory: directory),
                cleanupExecutor: CleanupExecutor(), deadline: .seconds(2), started: .now,
                unifiedHistoryStore: nil, historyAuthorization: nil)
        }
    }
}
