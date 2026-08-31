import Foundation

/// The recorder cannot suspend its realtime render callback when transcription
/// falls behind. This source therefore provides explicit, bounded backpressure:
/// it preserves the oldest queued chunks, reports dropped new chunks, and uses
/// monotonically increasing sequence numbers so a consumer can detect a gap.
final class BoundedAudioChunkStream: @unchecked Sendable {
    enum Termination: Equatable, Sendable {
        case finished
        case cancelled
    }

    enum YieldDisposition: Equatable, Sendable {
        case enqueued
        case dropped
        case terminated
    }

    let stream: AsyncStream<AudioChunk>

    private let lock = NSLock()
    private let continuation: AsyncStream<AudioChunk>.Continuation
    private var nextSequence: Int64 = 0
    private var storedTermination: Termination?
    private var storedDroppedChunkCount = 0

    init(bufferingLimit: Int) {
        precondition(bufferingLimit > 0, "Audio chunk buffering limit must be positive")

        var capturedContinuation: AsyncStream<AudioChunk>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingOldest(bufferingLimit)) {
            capturedContinuation = $0
        }
        continuation = capturedContinuation!
        continuation.onTermination = { [weak self] reason in
            self?.consumerTerminated(reason)
        }
    }

    var termination: Termination? {
        withLock { storedTermination }
    }

    var droppedChunkCount: Int {
        withLock { storedDroppedChunkCount }
    }

    @discardableResult
    func yield(samples: [Float], sampleRate: Int = 16_000) -> YieldDisposition {
        enqueue(copiedSamples: Array(samples), sampleRate: sampleRate)
    }

    @discardableResult
    func yield(
        copying samples: UnsafeBufferPointer<Float>,
        sampleRate: Int = 16_000
    ) -> YieldDisposition {
        enqueue(copiedSamples: Array(samples), sampleRate: sampleRate)
    }

    func finish() {
        terminate(as: .finished)
    }

    func cancel() {
        terminate(as: .cancelled)
    }

    private func enqueue(
        copiedSamples: [Float],
        sampleRate: Int
    ) -> YieldDisposition {
        let chunk: AudioChunk? = withLock {
            guard storedTermination == nil else { return nil }
            defer { nextSequence += 1 }
            return AudioChunk(
                samples: copiedSamples,
                sampleRate: sampleRate,
                sequence: nextSequence
            )
        }

        guard let chunk else { return .terminated }

        switch continuation.yield(chunk) {
        case .enqueued:
            return .enqueued
        case .dropped:
            withLock { storedDroppedChunkCount += 1 }
            return .dropped
        case .terminated:
            withLock {
                if storedTermination == nil {
                    storedTermination = .cancelled
                }
            }
            return .terminated
        @unknown default:
            return .terminated
        }
    }

    private func terminate(as termination: Termination) {
        let shouldFinish = withLock {
            guard storedTermination == nil else { return false }
            storedTermination = termination
            return true
        }

        if shouldFinish {
            continuation.finish()
        }
    }

    private func consumerTerminated(
        _ reason: AsyncStream<AudioChunk>.Continuation.Termination
    ) {
        withLock {
            guard storedTermination == nil else { return }
            switch reason {
            case .finished:
                storedTermination = .finished
            case .cancelled:
                storedTermination = .cancelled
            @unknown default:
                storedTermination = .cancelled
            }
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
