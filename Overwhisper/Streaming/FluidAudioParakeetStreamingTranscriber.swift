@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
import Foundation

/// True cache-aware Parakeet EOU streaming backed by FluidAudio 0.14.3's
/// external-buffer API. The pinned `.ms320` variant consumes our recorder's
/// samples; it never opens a microphone of its own.
actor FluidAudioParakeetStreamingTranscriber: StreamingTranscriber {
    private static let requiredSampleRate = 16_000

    private let manager: StreamingEouAsrManager
    private let modelRootURL: URL
    private let preparationDelay: Duration
    private var isPrepared = false
    private var preparationTask: Task<Void, Error>?

    private var sessionID: UUID?
    private var worker: Task<Void, Never>?
    private var finishingTask: Task<String, Error>?
    private var shutdown = StreamingShutdownDrain()
    private var outputContinuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var sessionFailure: StreamingTranscriberError?
    private var lastSequence: Int64?
    private var latestUpdate = TranscriptUpdate(finalized: "", volatile: "")
    private var startGeneration: UInt64 = 0

    init(
        manager: StreamingEouAsrManager = StreamingEouAsrManager(chunkSize: .ms320),
        modelRootURL: URL = FluidAudioParakeetStreamingTranscriber.defaultModelRootURL(),
        preparationDelay: Duration = .milliseconds(1_500)
    ) {
        self.manager = manager
        self.modelRootURL = modelRootURL
        self.preparationDelay = preparationDelay
    }

    func prepare() async throws {
        guard shutdown.task == nil else { throw CancellationError() }
        guard !isPrepared else { return }
        if let preparationTask {
            try await preparationTask.value
            try Task.checkCancellation()
            isPrepared = true
            return
        }

        let root = modelRootURL
        let manager = manager
        let task = Task<Void, Error> {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try await manager.loadModels(to: root)
            try Task.checkCancellation()
        }
        preparationTask = task
        do {
            try await task.value
            try Task.checkCancellation()
            preparationTask = nil
            isPrepared = true
        } catch {
            preparationTask = nil
            throw error
        }
    }

    func start(
        samples: AsyncStream<AudioChunk>
    ) async throws -> AsyncStream<TranscriptUpdate> {
        guard worker == nil, shutdown.task == nil else { throw StreamingTranscriberError.alreadyRunning }
        startGeneration &+= 1
        let generation = startGeneration

        // EOU is an optional preview aid. Delay its first preparation so short
        // dictations never compete with the authoritative batch engine, and so
        // onboarding/model readiness never depends on the auxiliary download.
        if !isPrepared {
            try await Task.sleep(for: preparationDelay)
            try await prepare()
        }
        try Task.checkCancellation()
        guard startGeneration == generation else { throw CancellationError() }

        await manager.reset()
        try Task.checkCancellation()
        guard startGeneration == generation else { throw CancellationError() }

        let id = UUID()
        let pair = AsyncStream<TranscriptUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.onTermination = { [weak self] reason in
            guard case .cancelled = reason else { return }
            Task { await self?.cancel(sessionID: id) }
        }

        sessionID = id
        outputContinuation = pair.continuation
        sessionFailure = nil
        lastSequence = nil
        latestUpdate = TranscriptUpdate(finalized: "", volatile: "")
        worker = Task { [weak self] in
            await self?.consume(samples, sessionID: id)
        }

        return pair.stream
    }

    func finish() async throws -> FinalTranscript {
        guard let id = sessionID, let worker else {
            throw StreamingTranscriberError.noActiveSession
        }
        guard finishingTask == nil else { throw StreamingTranscriberError.alreadyRunning }
        let task = Task { try await self.finishDecoder(sessionID: id, worker: worker) }
        finishingTask = task

        do {
            let tail = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard sessionID == id else { throw CancellationError() }
            finishingTask = nil
            let finalText = StreamingTranscriptText.join(
                latestUpdate.finalized,
                StreamingTranscriptText.normalized(tail).isEmpty
                    ? latestUpdate.volatile
                    : tail
            )
            let final = FinalTranscript(text: finalText, language: "en")
            outputContinuation?.yield(
                TranscriptUpdate(finalized: final.text, volatile: "")
            )
            closeSession(id: id)
            return final
        } catch {
            // A cancelled finish must never publish or clear a successor's
            // buffer after the decoder's asynchronous finish returns.
            if Task.isCancelled, sessionID == id {
                await cancelActiveWork()
                throw CancellationError()
            }
            guard sessionID == id, !Task.isCancelled else { throw CancellationError() }
            finishingTask = nil
            let failure = StreamingTranscriberError.inferenceFailed(
                error.localizedDescription
            )
            closeSession(id: id)
            throw failure
        }
    }

    private func finishDecoder(sessionID id: UUID, worker: Task<Void, Never>) async throws -> String {
        // Drain recorded chunks before flushing the decoder tail. This whole
        // operation is retained so cancellation waits before resetting it.
        await worker.value
        try Task.checkCancellation()
        guard sessionID == id else { throw CancellationError() }
        if let sessionFailure { throw sessionFailure }
        return try await manager.finish()
    }

    func cancel() async {
        startGeneration &+= 1
        await cancelActiveWork()
    }

    private func consume(
        _ samples: AsyncStream<AudioChunk>,
        sessionID id: UUID
    ) async {
        do {
            for await chunk in samples {
                try Task.checkCancellation()
                guard sessionID == id else { return }
                try validate(chunk)
                guard !chunk.samples.isEmpty else { continue }

                let buffer = try makePCMBuffer(from: chunk.samples)
                try await manager.appendAudio(buffer)
                try await manager.processBufferedAudio()

                let partial = await manager.getPartialTranscript()
                let reachedEndOfUtterance = await manager.eouDetected
                publish(partial: partial, reachedEndOfUtterance: reachedEndOfUtterance)

                if reachedEndOfUtterance {
                    // Reset only decoder/session state. Loaded model warmth remains,
                    // while the committed text stays in our replacement buffer.
                    await manager.reset()
                }
            }
        } catch is CancellationError {
            return
        } catch let error as StreamingTranscriberError {
            failSession(error, id: id)
        } catch {
            failSession(.inferenceFailed(error.localizedDescription), id: id)
        }
    }

    private func validate(_ chunk: AudioChunk) throws {
        guard chunk.sampleRate == Self.requiredSampleRate else {
            throw StreamingTranscriberError.unsupportedSampleRate(
                expected: Self.requiredSampleRate,
                actual: chunk.sampleRate
            )
        }

        if let lastSequence, chunk.sequence != lastSequence + 1 {
            throw StreamingTranscriberError.inferenceFailed(
                "Audio chunk sequence jumped from \(lastSequence) to \(chunk.sequence); "
                    + "the bounded recorder stream overflowed"
            )
        }
        lastSequence = chunk.sequence
    }

    private func makePCMBuffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.requiredSampleRate),
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ),
        let channel = buffer.floatChannelData?[0]
        else {
            throw StreamingTranscriberError.inferenceFailed(
                "Could not allocate a 16 kHz mono FluidAudio input buffer"
            )
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)
        return buffer
    }

    private func publish(partial: String, reachedEndOfUtterance: Bool) {
        let partial = StreamingTranscriptText.normalized(partial)
        let update: TranscriptUpdate

        if reachedEndOfUtterance {
            update = TranscriptUpdate(
                finalized: StreamingTranscriptText.join(latestUpdate.finalized, partial),
                volatile: ""
            )
        } else {
            update = TranscriptUpdate(
                finalized: latestUpdate.finalized,
                volatile: partial
            )
        }

        guard update != latestUpdate else { return }
        latestUpdate = update
        outputContinuation?.yield(update)
    }

    private func failSession(_ error: StreamingTranscriberError, id: UUID) {
        guard sessionID == id else { return }
        sessionFailure = error
        outputContinuation?.finish()
    }

    private func closeSession(id: UUID) {
        guard sessionID == id else { return }
        outputContinuation?.finish()
        outputContinuation = nil
        worker = nil
        finishingTask = nil
        sessionID = nil
        sessionFailure = nil
        lastSequence = nil
    }

    private func cancel(sessionID id: UUID) async {
        guard sessionID == id else { return }
        await cancelActiveWork()
    }

    private func cancelActiveWork() async {
        if let pending = shutdown.task {
            await pending.value
            return
        }
        guard preparationTask != nil || worker != nil || finishingTask != nil || sessionID != nil else { return }
        let preparation = preparationTask
        let activeWorker = worker
        let finish = finishingTask
        let continuation = outputContinuation
        let manager = manager

        sessionID = nil
        outputContinuation = nil
        sessionFailure = nil
        lastSequence = nil

        preparation?.cancel()
        activeWorker?.cancel()
        finish?.cancel()
        continuation?.finish()
        // Keep start() closed until this exact worker and its reset have
        // drained. Otherwise an immediate restart could be reset by this old
        // cancellation after it has already acquired a new session.
        let pending = shutdown.begin {
            _ = try? await preparation?.value
            await activeWorker?.value
            _ = try? await finish?.value
            await manager.reset()
        }
        await pending.value
        preparationTask = nil
        worker = nil
        finishingTask = nil
        shutdown.clear()
    }

    nonisolated private static func defaultModelRootURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("LocalDictation", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("eou-preview", isDirectory: true)
            .appendingPathComponent("fluidaudio-0.14.3", isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
    }
}

enum StreamingTranscriptText {
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func join(_ lhs: String, _ rhs: String) -> String {
        let left = normalized(lhs)
        let right = normalized(rhs)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        return "\(left) \(right)"
    }
}
