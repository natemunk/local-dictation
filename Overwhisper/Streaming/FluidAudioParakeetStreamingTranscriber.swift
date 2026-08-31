@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
import Foundation

/// True cache-aware Parakeet EOU streaming backed by FluidAudio 0.14.3's
/// external-buffer API. The pinned `.ms320` variant consumes our recorder's
/// samples; it never opens a microphone of its own.
actor FluidAudioParakeetStreamingTranscriber: StreamingTranscriber {
    private static let requiredSampleRate = 16_000

    private let manager: StreamingEouAsrManager
    private var isPrepared = false

    private var sessionID: UUID?
    private var worker: Task<Void, Never>?
    private var outputContinuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var sessionFailure: StreamingTranscriberError?
    private var lastSequence: Int64?
    private var latestUpdate = TranscriptUpdate(finalized: "", volatile: "")

    init(
        manager: StreamingEouAsrManager = StreamingEouAsrManager(chunkSize: .ms320)
    ) {
        self.manager = manager
    }

    func prepare() async throws {
        guard !isPrepared else { return }
        try await manager.loadModels()
        isPrepared = true
    }

    func start(
        samples: AsyncStream<AudioChunk>
    ) async throws -> AsyncStream<TranscriptUpdate> {
        guard isPrepared else { throw StreamingTranscriberError.notPrepared }
        guard worker == nil else { throw StreamingTranscriberError.alreadyRunning }

        await manager.reset()

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

        // The recorder finishes its AsyncStream after AudioOutputUnitStop. Drain
        // that bounded buffer before flushing FluidAudio's decoder tail.
        await worker.value
        guard sessionID == id else { throw StreamingTranscriberError.noActiveSession }

        if let sessionFailure {
            closeSession(id: id)
            throw sessionFailure
        }

        do {
            let tail = try await manager.finish()
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
            let failure = StreamingTranscriberError.inferenceFailed(
                error.localizedDescription
            )
            closeSession(id: id)
            throw failure
        }
    }

    func cancel() async {
        guard let id = sessionID else { return }
        await cancel(sessionID: id)
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
        sessionID = nil
        sessionFailure = nil
        lastSequence = nil
    }

    private func cancel(sessionID id: UUID) async {
        guard sessionID == id else { return }
        let activeWorker = worker
        let continuation = outputContinuation

        sessionID = nil
        worker = nil
        outputContinuation = nil
        sessionFailure = nil
        lastSequence = nil

        activeWorker?.cancel()
        continuation?.finish()
        await manager.reset()
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
