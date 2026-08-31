import Foundation
import Testing
@testable import LocalDictation

@Suite("Streaming transcriber lifecycle")
struct StreamingLifecycleTests {
    @Test("prepare stays separate and inference follows chunk delivery")
    func eventDrivenLifecycle() async throws {
        let input = BoundedAudioChunkStream(bufferingLimit: 4)
        let transcriber = FakeStreamingTranscriber()

        try await transcriber.prepare()
        let beforeStart = await transcriber.snapshot()
        #expect(beforeStart.prepareCount == 1)
        #expect(beforeStart.inferenceCount == 0)

        let updates = try await transcriber.start(samples: input.stream)
        let collector = Task { await collect(updates) }
        input.yield(samples: [0.25])
        input.finish()

        let final = try await transcriber.finish()
        let received = await collector.value
        let finished = await transcriber.snapshot()

        #expect(finished.inferenceCount == 1)
        #expect(finished.finishCount == 1)
        #expect(final == FinalTranscript(text: "chunk 0", language: "en"))
        #expect(received.last == TranscriptUpdate(finalized: "chunk 0", volatile: ""))
    }

    @Test("cancel stops the consumer and closes transcript updates")
    func cancelLifecycle() async throws {
        let input = BoundedAudioChunkStream(bufferingLimit: 4)
        let transcriber = FakeStreamingTranscriber()

        try await transcriber.prepare()
        let updates = try await transcriber.start(samples: input.stream)
        let collector = Task { await collect(updates) }

        await transcriber.cancel()
        let received = await collector.value
        let cancelled = await transcriber.snapshot()

        #expect(cancelled.cancelCount == 1)
        #expect(cancelled.inferenceCount == 0)
        #expect(received.isEmpty)
        input.cancel()
    }

    private func collect(_ stream: AsyncStream<TranscriptUpdate>) async -> [TranscriptUpdate] {
        var updates: [TranscriptUpdate] = []
        for await update in stream {
            updates.append(update)
        }
        return updates
    }
}

private actor FakeStreamingTranscriber: StreamingTranscriber {
    struct Snapshot: Sendable {
        let prepareCount: Int
        let inferenceCount: Int
        let finishCount: Int
        let cancelCount: Int
    }

    private var prepared = false
    private var active = false
    private var prepareCount = 0
    private var inferenceCount = 0
    private var finishCount = 0
    private var cancelCount = 0
    private var text = ""
    private var worker: Task<Void, Never>?
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?

    func prepare() async throws {
        prepared = true
        prepareCount += 1
    }

    func start(
        samples: AsyncStream<AudioChunk>
    ) async throws -> AsyncStream<TranscriptUpdate> {
        guard prepared else { throw StreamingTranscriberError.notPrepared }
        guard !active else { throw StreamingTranscriberError.alreadyRunning }

        let pair = AsyncStream<TranscriptUpdate>.makeStream()
        active = true
        continuation = pair.continuation
        worker = Task { [weak self] in
            for await chunk in samples {
                guard !Task.isCancelled else { return }
                await self?.consume(chunk)
            }
        }
        return pair.stream
    }

    func finish() async throws -> FinalTranscript {
        guard active, let worker else {
            throw StreamingTranscriberError.noActiveSession
        }
        await worker.value
        finishCount += 1
        let final = FinalTranscript(text: text, language: "en")
        continuation?.yield(TranscriptUpdate(finalized: text, volatile: ""))
        continuation?.finish()
        continuation = nil
        self.worker = nil
        active = false
        return final
    }

    func cancel() async {
        guard active else { return }
        cancelCount += 1
        worker?.cancel()
        continuation?.finish()
        worker = nil
        continuation = nil
        active = false
    }

    func snapshot() -> Snapshot {
        Snapshot(
            prepareCount: prepareCount,
            inferenceCount: inferenceCount,
            finishCount: finishCount,
            cancelCount: cancelCount
        )
    }

    private func consume(_ chunk: AudioChunk) {
        inferenceCount += 1
        text = StreamingTranscriptText.join(text, "chunk \(chunk.sequence)")
        continuation?.yield(TranscriptUpdate(finalized: "", volatile: text))
    }
}
