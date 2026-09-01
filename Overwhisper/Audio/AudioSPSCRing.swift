import Synchronization

/// A fixed-capacity, single-producer/single-consumer audio ring.
///
/// The ring owns all slot storage up front. Each slot stores planar Float32
/// samples as `channel * maxFrames + frame`, so a producer can render directly
/// into a claimed slot without creating an array or an audio buffer. The
/// producer and consumer must each have only one caller. A claimed slot must be
/// published or cancelled before that side claims another slot.
///
/// Producer publication and consumer release are the synchronization points:
/// the producer releases its write position after writing samples and metadata,
/// and the consumer acquires that position before reading them. The consumer
/// releases its read position only after it is done reading, which prevents the
/// producer from overwriting unread storage.
final class AudioSPSCRing: @unchecked Sendable {
    /// A producer-owned view into one preallocated slot.
    struct ProducerSlot: @unchecked Sendable {
        let frameCount: Int
        let channels: Int
        let maxFrames: Int

        fileprivate let position: UInt64
        fileprivate let token: UInt64
        fileprivate let storage: UnsafeMutablePointer<Float>

        /// The complete channel-major slot storage. Only the first
        /// `frameCount` values of each channel are part of this item.
        var samples: UnsafeMutableBufferPointer<Float> {
            UnsafeMutableBufferPointer(
                start: storage,
                count: maxFrames * channels
            )
        }

        /// Alias that makes the channel-major layout explicit at call sites.
        var planarSamples: UnsafeMutableBufferPointer<Float> {
            samples
        }

        /// Returns the writable plane for one channel. The returned buffer is
        /// limited to this item's frame count, not the slot's capacity.
        @inline(__always)
        func channel(_ channel: Int) -> UnsafeMutableBufferPointer<Float> {
            precondition(channel >= 0 && channel < channels, "Audio channel is out of range")
            return UnsafeMutableBufferPointer(
                start: storage.advanced(by: channel * maxFrames),
                count: frameCount
            )
        }

        @inline(__always)
        subscript(channel channel: Int, frame frame: Int) -> Float {
            get {
                precondition(channel >= 0 && channel < channels, "Audio channel is out of range")
                precondition(frame >= 0 && frame < frameCount, "Audio frame is out of range")
                return storage[ channel * maxFrames + frame ]
            }
            nonmutating set {
                precondition(channel >= 0 && channel < channels, "Audio channel is out of range")
                precondition(frame >= 0 && frame < frameCount, "Audio frame is out of range")
                storage[ channel * maxFrames + frame ] = newValue
            }
        }
    }

    /// A consumer-owned read-only view into one published slot.
    struct ConsumerSlot: @unchecked Sendable {
        let frameCount: Int
        let channels: Int
        let maxFrames: Int

        fileprivate let position: UInt64
        fileprivate let token: UInt64
        fileprivate let storage: UnsafeMutablePointer<Float>

        /// The complete channel-major slot storage. Only the first
        /// `frameCount` values of each channel are part of this item.
        var samples: UnsafeBufferPointer<Float> {
            UnsafeBufferPointer(
                start: UnsafePointer(storage),
                count: maxFrames * channels
            )
        }

        /// Alias that makes the channel-major layout explicit at call sites.
        var planarSamples: UnsafeBufferPointer<Float> {
            samples
        }

        /// Returns the readable plane for one channel.
        @inline(__always)
        func channel(_ channel: Int) -> UnsafeBufferPointer<Float> {
            precondition(channel >= 0 && channel < channels, "Audio channel is out of range")
            return UnsafeBufferPointer(
                start: UnsafePointer(storage.advanced(by: channel * maxFrames)),
                count: frameCount
            )
        }

        @inline(__always)
        subscript(channel channel: Int, frame frame: Int) -> Float {
            get {
                precondition(channel >= 0 && channel < channels, "Audio channel is out of range")
                precondition(frame >= 0 && frame < frameCount, "Audio frame is out of range")
                return storage[ channel * maxFrames + frame ]
            }
        }
    }

    private struct Slot {
        let storage: UnsafeMutablePointer<Float>
        var frameCount: Int = 0
    }

    private enum Lifecycle {
        static let running: UInt8 = 0
        static let stopped: UInt8 = 1
        static let resetting: UInt8 = 2
    }

    let capacity: Int
    let maxFrames: Int
    let channels: Int

    private let capacityUInt64: UInt64
    private let slotSampleCount: Int
    private let slots: UnsafeMutablePointer<Slot>

    // Positions are monotonically increasing sequence numbers. They are
    // intentionally not truncated to a slot index; that lets full and empty
    // be distinguished even when capacity is not a power of two.
    private let producerPosition = Atomic<UInt64>(0)
    private let consumerPosition = Atomic<UInt64>(0)

    // These flags make reset/drain state observable while a caller owns a
    // claimed slot. SPSC operation still permits at most one active claim per
    // side, but the flags make accidental nested claims fail safely and keep a
    // stop followed immediately by a drain from racing an in-flight callback.
    private let producerClaimActive = Atomic<Bool>(false)
    private let consumerClaimActive = Atomic<Bool>(false)
    private let producerClaimToken = Atomic<UInt64>(0)
    private let consumerClaimToken = Atomic<UInt64>(0)
    private let activeProducerToken = Atomic<UInt64>(0)
    private let activeConsumerToken = Atomic<UInt64>(0)

    private let lifecycle = Atomic<UInt8>(Lifecycle.running)
    private let overflowCounter = Atomic<UInt64>(0)

    /// Returns the largest capacity whose per-slot sample-count arithmetic is
    /// representable by `Int`.
    ///
    /// This is an arithmetic ceiling, not a promise that allocating that much
    /// memory is practical. The initializer enforces it before allocating any
    /// slot storage.
    static func capacityCeiling(maxFrames: Int, channels: Int) -> Int {
        guard maxFrames > 0, channels > 0 else { return 0 }
        let product = maxFrames.multipliedReportingOverflow(by: channels)
        guard !product.overflow, product.partialValue > 0 else { return 0 }
        let sampleStorageCeiling = Int.max / product.partialValue
        let slotTableCeiling = Int.max / max(1, MemoryLayout<Slot>.stride)
        return min(sampleStorageCeiling, slotTableCeiling)
    }

    init(capacity: Int, maxFrames: Int, channels: Int) {
        precondition(capacity > 0, "Audio ring capacity must be positive")
        precondition(maxFrames > 0, "Audio ring maxFrames must be positive")
        precondition(channels > 0, "Audio ring channels must be positive")

        let product = maxFrames.multipliedReportingOverflow(by: channels)
        precondition(!product.overflow && product.partialValue > 0, "Audio ring slot size overflows Int")
        precondition(
            capacity <= Self.capacityCeiling(maxFrames: maxFrames, channels: channels),
            "Audio ring capacity exceeds its arithmetic ceiling"
        )

        self.capacity = capacity
        self.maxFrames = maxFrames
        self.channels = channels
        self.capacityUInt64 = UInt64(capacity)
        self.slotSampleCount = product.partialValue
        self.slots = UnsafeMutablePointer<Slot>.allocate(capacity: capacity)

        for index in 0..<capacity {
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: product.partialValue)
            storage.initialize(repeating: 0, count: product.partialValue)
            slots.advanced(by: index).initialize(to: Slot(storage: storage))
        }
    }

    deinit {
        for index in 0..<capacity {
            let slot = slots.advanced(by: index).pointee
            slot.storage.deinitialize(count: slotSampleCount)
            slot.storage.deallocate()
            slots.advanced(by: index).deinitialize(count: 1)
        }
        slots.deallocate()
    }

    /// Number of published items waiting for the consumer.
    var count: Int {
        let producer = producerPosition.load(ordering: .acquiring)
        let consumer = consumerPosition.load(ordering: .acquiring)
        return Int(min(producer &- consumer, capacityUInt64))
    }

    /// Alias for `count` useful at a consumer call site.
    var availableCount: Int { count }

    /// Number of free slots available to the producer.
    var freeCapacity: Int { capacity - count }

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count == capacity }

    /// Number of producer claims rejected because every slot was unread.
    var overflowCount: UInt64 {
        overflowCounter.load(ordering: .acquiring)
    }

    /// Alias for callers that use dropped-item terminology.
    var droppedCount: UInt64 { overflowCount }

    /// True after `stop()` until a successful `reset()`.
    var isStopped: Bool {
        lifecycle.load(ordering: .acquiring) == Lifecycle.stopped
    }

    /// True when no published or in-flight item remains.
    ///
    /// A stopped ring can be drained by repeatedly claiming and releasing
    /// consumer slots, then checked with this property before resetting.
    var isDrained: Bool {
        guard isEmpty else { return false }
        return !producerClaimActive.load(ordering: .acquiring)
            && !consumerClaimActive.load(ordering: .acquiring)
    }

    /// Stop accepting new producer claims. Published items remain available to
    /// the consumer, and a producer claim already in progress may still be
    /// published so a caller can stop and then drain deterministically.
    func stop() {
        lifecycle.store(Lifecycle.stopped, ordering: .releasing)
    }

    /// Synonym for `stop()` for stream-style call sites.
    func finish() {
        stop()
    }

    /// Reset an empty ring for reuse.
    ///
    /// Reset is allowed while running or stopped, but only when neither side
    /// owns a claim and no item is queued. It returns `false` without changing
    /// the queued data when those conditions are not met.
    @discardableResult
    func reset() -> Bool {
        let previousState: UInt8

        while true {
            let state = lifecycle.load(ordering: .acquiring)
            guard state == Lifecycle.running || state == Lifecycle.stopped else {
                return false
            }

            let exchange = lifecycle.compareExchange(
                expected: state,
                desired: Lifecycle.resetting,
                ordering: .acquiringAndReleasing
            )
            if exchange.exchanged {
                previousState = state
                break
            }
        }

        guard !producerClaimActive.load(ordering: .acquiring),
              !consumerClaimActive.load(ordering: .acquiring),
              producerPosition.load(ordering: .acquiring)
                == consumerPosition.load(ordering: .acquiring) else {
            lifecycle.store(previousState, ordering: .releasing)
            return false
        }

        producerPosition.store(0, ordering: .relaxed)
        consumerPosition.store(0, ordering: .relaxed)
        overflowCounter.store(0, ordering: .relaxed)

        for index in 0..<capacity {
            slots.advanced(by: index).pointee.frameCount = 0
        }

        lifecycle.store(Lifecycle.running, ordering: .releasing)
        return true
    }

    /// Claim an empty slot for the producer. The returned value is a stack
    /// view over preallocated storage; it does not own or allocate samples.
    @discardableResult
    @inline(__always)
    func tryClaimProducer(frameCount: Int) -> ProducerSlot? {
        guard frameCount >= 0 && frameCount <= maxFrames else { return nil }

        let claim = producerClaimActive.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        guard claim.exchanged else { return nil }

        guard lifecycle.load(ordering: .acquiring) == Lifecycle.running else {
            producerClaimActive.store(false, ordering: .releasing)
            return nil
        }

        let producer = producerPosition.load(ordering: .relaxed)
        let consumer = consumerPosition.load(ordering: .acquiring)
        guard producer &- consumer < capacityUInt64 else {
            producerClaimActive.store(false, ordering: .releasing)
            overflowCounter.wrappingAdd(1, ordering: .relaxed)
            return nil
        }

        let index = Int(producer % capacityUInt64)
        let token = producerClaimToken.wrappingAdd(1, ordering: .relaxed).newValue
        activeProducerToken.store(token, ordering: .relaxed)
        slots.advanced(by: index).pointee.frameCount = frameCount

        return ProducerSlot(
            frameCount: frameCount,
            channels: channels,
            maxFrames: maxFrames,
            position: producer,
            token: token,
            storage: slots.advanced(by: index).pointee.storage
        )
    }

    /// Publish a previously claimed producer slot.
    @discardableResult
    @inline(__always)
    func publish(_ slot: ProducerSlot) -> Bool {
        guard producerClaimActive.load(ordering: .acquiring),
              activeProducerToken.load(ordering: .relaxed) == slot.token,
              producerPosition.load(ordering: .relaxed) == slot.position else {
            return false
        }

        // The release store makes the slot's samples and frameCount visible to
        // a consumer that acquires producerPosition.
        producerPosition.store(slot.position &+ 1, ordering: .releasing)
        producerClaimActive.store(false, ordering: .releasing)
        return true
    }

    /// Abandon a producer claim without publishing it. This is useful when a
    /// render callback is stopped after claiming but before it has data.
    @discardableResult
    @inline(__always)
    func cancelProducerClaim(_ slot: ProducerSlot) -> Bool {
        guard producerClaimActive.load(ordering: .acquiring),
              activeProducerToken.load(ordering: .relaxed) == slot.token,
              producerPosition.load(ordering: .relaxed) == slot.position else {
            return false
        }
        producerClaimActive.store(false, ordering: .releasing)
        return true
    }

    /// Claim, render, and publish one slot. The closure is nonescaping by
    /// default and receives only the already allocated slot view.
    @discardableResult
    func withProducerBuffer(
        frameCount: Int,
        _ render: (inout ProducerSlot) -> Void
    ) -> Bool {
        guard var slot = tryClaimProducer(frameCount: frameCount) else { return false }
        render(&slot)
        return publish(slot)
    }

    /// Copy packed planar source data into a preallocated slot. The source is
    /// laid out as all `frameCount` samples for channel 0, then channel 1, and
    /// so on. This method performs no sample-storage allocation itself.
    @discardableResult
    func enqueue(
        copying packedPlanarSamples: UnsafeBufferPointer<Float>,
        frameCount: Int
    ) -> Bool {
        guard frameCount >= 0 && frameCount <= maxFrames else { return false }
        let requiredSamples = frameCount * channels
        guard packedPlanarSamples.count >= requiredSamples else { return false }
        guard let slot = tryClaimProducer(frameCount: frameCount) else { return false }

        if frameCount > 0, let source = packedPlanarSamples.baseAddress {
            for channel in 0..<channels {
                let sourcePlane = source.advanced(by: channel * frameCount)
                let destinationPlane = slot.channel(channel)
                destinationPlane.baseAddress!.update(from: sourcePlane, count: frameCount)
            }
        }

        return publish(slot)
    }

    /// Claim the oldest published slot for the consumer.
    @discardableResult
    @inline(__always)
    func tryClaimConsumer() -> ConsumerSlot? {
        let claim = consumerClaimActive.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        )
        guard claim.exchanged else { return nil }

        let state = lifecycle.load(ordering: .acquiring)
        guard state == Lifecycle.running || state == Lifecycle.stopped else {
            consumerClaimActive.store(false, ordering: .releasing)
            return nil
        }

        let consumer = consumerPosition.load(ordering: .relaxed)
        let producer = producerPosition.load(ordering: .acquiring)
        guard consumer != producer else {
            consumerClaimActive.store(false, ordering: .releasing)
            return nil
        }

        let index = Int(consumer % capacityUInt64)
        let slot = slots.advanced(by: index).pointee
        let token = consumerClaimToken.wrappingAdd(1, ordering: .relaxed).newValue
        activeConsumerToken.store(token, ordering: .relaxed)

        return ConsumerSlot(
            frameCount: slot.frameCount,
            channels: channels,
            maxFrames: maxFrames,
            position: consumer,
            token: token,
            storage: slot.storage
        )
    }

    /// Release a previously claimed consumer slot, making its storage
    /// available to the producer again.
    @discardableResult
    @inline(__always)
    func release(_ slot: ConsumerSlot) -> Bool {
        guard consumerClaimActive.load(ordering: .acquiring),
              activeConsumerToken.load(ordering: .relaxed) == slot.token,
              consumerPosition.load(ordering: .relaxed) == slot.position else {
            return false
        }

        // The release store prevents the producer from reusing this slot until
        // all consumer reads performed through the claimed view are complete.
        consumerPosition.store(slot.position &+ 1, ordering: .releasing)
        consumerClaimActive.store(false, ordering: .releasing)
        return true
    }

    /// Claim, consume, and release the oldest published slot.
    @discardableResult
    func withConsumerBuffer(_ consume: (ConsumerSlot) -> Void) -> Bool {
        guard let slot = tryClaimConsumer() else { return false }
        consume(slot)
        return release(slot)
    }
}
