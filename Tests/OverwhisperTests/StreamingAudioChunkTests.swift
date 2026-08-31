import Foundation
import Testing
@testable import LocalDictation

@Suite("Bounded streaming audio delivery")
struct StreamingAudioChunkTests {
    @Test("finished streams drain copied chunks and reject later delivery")
    func finishLifecycle() async {
        let source = BoundedAudioChunkStream(bufferingLimit: 4)
        var original: [Float] = [0.1, 0.2]

        #expect(source.yield(samples: original) == .enqueued)
        original[0] = 9
        source.finish()

        #expect(source.yield(samples: [0.3]) == .terminated)
        #expect(source.termination == .finished)

        let chunks = await collect(source.stream)
        #expect(chunks == [AudioChunk(samples: [0.1, 0.2], sampleRate: 16_000, sequence: 0)])
    }

    @Test("bounded delivery preserves queued chronology and reports pressure")
    func boundedDelivery() async {
        let source = BoundedAudioChunkStream(bufferingLimit: 2)

        #expect(source.yield(samples: [0]) == .enqueued)
        #expect(source.yield(samples: [1]) == .enqueued)
        #expect(source.yield(samples: [2]) == .dropped)
        #expect(source.droppedChunkCount == 1)
        source.finish()

        let chunks = await collect(source.stream)
        #expect(chunks.map(\.sequence) == [0, 1])
        #expect(chunks.map { $0.samples[0] } == [0, 1])
    }

    @Test("cancel is terminal and idempotent")
    func cancelLifecycle() async {
        let source = BoundedAudioChunkStream(bufferingLimit: 2)
        #expect(source.yield(samples: [1]) == .enqueued)

        source.cancel()
        source.cancel()

        #expect(source.termination == .cancelled)
        #expect(source.yield(samples: [2]) == .terminated)
        _ = await collect(source.stream)
    }

    private func collect(_ stream: AsyncStream<AudioChunk>) async -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        for await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }
}
