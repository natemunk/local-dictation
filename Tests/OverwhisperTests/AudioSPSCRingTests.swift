import Testing
@testable import LocalDictation

@Suite("Audio SPSC ring")
struct AudioSPSCRingTests {
    @Test("wraparound preserves order across non-power-of-two capacity")
    func wraparound() {
        let ring = AudioSPSCRing(capacity: 3, maxFrames: 2, channels: 1)

        for value in 0..<24 {
            #expect(ring.withProducerBuffer(frameCount: 1) { slot in
                slot[channel: 0, frame: 0] = Float(value)
            })

            guard let slot = ring.tryClaimConsumer() else {
                Issue.record("Expected a published slot for value \(value)")
                return
            }
            #expect(slot.frameCount == 1)
            #expect(slot[channel: 0, frame: 0] == Float(value))
            #expect(ring.release(slot))
        }

        #expect(ring.count == 0)
        #expect(ring.overflowCount == 0)
    }

    @Test("full capacity rejects the newest item and counts overflow")
    func overflow() {
        let ring = AudioSPSCRing(capacity: 2, maxFrames: 1, channels: 1)

        #expect(enqueue(10, into: ring))
        #expect(enqueue(20, into: ring))
        #expect(!enqueue(30, into: ring))
        #expect(ring.isFull)
        #expect(ring.overflowCount == 1)

        guard let first = ring.tryClaimConsumer() else {
            Issue.record("Expected the first queued item")
            return
        }
        #expect(first[channel: 0, frame: 0] == 10)
        #expect(ring.release(first))

        #expect(enqueue(30, into: ring))
        #expect(ring.overflowCount == 1)
    }

    @Test("copying packed planar data preserves each channel")
    func multichannelCopying() {
        let ring = AudioSPSCRing(capacity: 2, maxFrames: 4, channels: 3)
        let source: [Float] = [1, 2, 3, 10, 20, 30, 100, 200, 300]

        let copied = source.withUnsafeBufferPointer {
            ring.enqueue(copying: $0, frameCount: 3)
        }
        #expect(copied)

        guard let slot = ring.tryClaimConsumer() else {
            Issue.record("Expected copied planar data")
            return
        }
        #expect(Array(slot.channel(0)) == [1, 2, 3])
        #expect(Array(slot.channel(1)) == [10, 20, 30])
        #expect(Array(slot.channel(2)) == [100, 200, 300])
        #expect(ring.release(slot))
    }

    @Test("capacity ceiling rejects invalid arithmetic and matches slot sizing")
    func capacityCeiling() {
        #expect(AudioSPSCRing.capacityCeiling(maxFrames: 7, channels: 3) == Int.max / 21)
        #expect(AudioSPSCRing.capacityCeiling(maxFrames: 0, channels: 3) == 0)
        #expect(AudioSPSCRing.capacityCeiling(maxFrames: 3, channels: 0) == 0)
        #expect(AudioSPSCRing.capacityCeiling(maxFrames: Int.max, channels: 2) == 0)
    }

    @Test("a stopped and drained ring resets for reuse")
    func resetAndReuse() {
        let ring = AudioSPSCRing(capacity: 2, maxFrames: 1, channels: 1)
        #expect(enqueue(1, into: ring))
        #expect(enqueue(2, into: ring))
        #expect(!enqueue(3, into: ring))

        ring.stop()
        #expect(ring.isStopped)
        drain(ring)
        #expect(ring.isDrained)
        #expect(ring.reset())
        #expect(!ring.isStopped)
        #expect(ring.overflowCount == 0)
        #expect(ring.count == 0)

        #expect(enqueue(42, into: ring))
        guard let slot = ring.tryClaimConsumer() else {
            Issue.record("Expected the reused ring to publish")
            return
        }
        #expect(slot[channel: 0, frame: 0] == 42)
        #expect(ring.release(slot))
    }

    @Test("stop leaves queued items available for ordered drain")
    func orderedDrain() {
        let ring = AudioSPSCRing(capacity: 4, maxFrames: 1, channels: 2)
        for value in 0..<4 {
            #expect(ring.withProducerBuffer(frameCount: 1) { slot in
                slot[channel: 0, frame: 0] = Float(value)
                slot[channel: 1, frame: 0] = Float(value + 100)
            })
        }

        ring.finish()
        var drained: [(Float, Float)] = []
        while let slot = ring.tryClaimConsumer() {
            drained.append((slot[channel: 0, frame: 0], slot[channel: 1, frame: 0]))
            #expect(ring.release(slot))
        }

        #expect(drained.map(\.0) == [0, 1, 2, 3])
        #expect(drained.map(\.1) == [100, 101, 102, 103])
        #expect(ring.isDrained)
        #expect(!enqueue(999, into: ring))
    }

    @Test("a concurrent producer and consumer preserve every published value")
    func concurrentStress() async {
        let itemCount = 25_000
        let ring = AudioSPSCRing(capacity: 31, maxFrames: 1, channels: 1)

        let producer = Task.detached {
            for value in 0..<itemCount {
                while !ring.withProducerBuffer(frameCount: 1, { slot in
                    slot[channel: 0, frame: 0] = Float(value)
                }) {
                    await Task.yield()
                }
            }
            ring.stop()
        }
        let consumer = Task.detached { () -> [Int] in
            var values: [Int] = []
            values.reserveCapacity(itemCount)
            while true {
                if let slot = ring.tryClaimConsumer() {
                    values.append(Int(slot[channel: 0, frame: 0]))
                    _ = ring.release(slot)
                } else if ring.isStopped, ring.isDrained {
                    return values
                } else {
                    await Task.yield()
                }
            }
        }

        await producer.value
        let values = await consumer.value
        #expect(values == Array(0..<itemCount))
    }

    private func enqueue(_ value: Float, into ring: AudioSPSCRing) -> Bool {
        ring.withProducerBuffer(frameCount: 1) { slot in
            slot[channel: 0, frame: 0] = value
        }
    }

    private func drain(_ ring: AudioSPSCRing) {
        while let slot = ring.tryClaimConsumer() {
            #expect(ring.release(slot))
        }
    }
}
