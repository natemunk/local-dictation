import AudioToolbox
import Foundation
import Synchronization
import Darwin.Mach

private final class PlanarAudioBufferList {
    let pointer: UnsafeMutablePointer<AudioBufferList>

    private let channelCount: Int
    private let maximumFrames: Int
    private let rawStorage: UnsafeMutableRawPointer
    private let ownedPlanes: [UnsafeMutablePointer<Float>]

    init(channels: Int, maximumFrames: Int, ownsSampleStorage: Bool) {
        precondition(channels > 0)
        precondition(maximumFrames > 0)
        channelCount = channels
        self.maximumFrames = maximumFrames

        let byteCount = MemoryLayout<AudioBufferList>.size
            + max(0, channels - 1) * MemoryLayout<AudioBuffer>.stride
        rawStorage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        rawStorage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        pointer = rawStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.initialize(
            to: AudioBufferList(
                mNumberBuffers: UInt32(channels),
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(maximumFrames * MemoryLayout<Float>.size),
                    mData: nil
                )
            )
        )

        if ownsSampleStorage {
            ownedPlanes = (0..<channels).map { _ in
                let plane = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames)
                plane.initialize(repeating: 0, count: maximumFrames)
                return plane
            }
            prepareOwned(frameCount: maximumFrames)
        } else {
            ownedPlanes = []
        }
    }

    deinit {
        for plane in ownedPlanes {
            plane.deinitialize(count: maximumFrames)
            plane.deallocate()
        }
        pointer.deinitialize(count: 1)
        rawStorage.deallocate()
    }

    @inline(__always)
    func target(_ slot: AudioSPSCRing.ProducerSlot) {
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        let dataByteSize = UInt32(slot.frameCount * MemoryLayout<Float>.size)
        for channel in 0..<channelCount {
            buffers[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: dataByteSize,
                mData: slot.channel(channel).baseAddress
            )
        }
    }

    @inline(__always)
    func prepareOwned(frameCount: Int) {
        precondition(!ownedPlanes.isEmpty)
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        let dataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
        for channel in 0..<channelCount {
            buffers[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: dataByteSize,
                mData: ownedPlanes[channel]
            )
        }
    }
}

private struct AudioMachTimebase: Sendable {
    let numerator: UInt64
    let denominator: UInt64

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        numerator = UInt64(info.numer)
        denominator = UInt64(info.denom)
    }

    func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        guard end >= start, denominator > 0 else { return 0 }
        return Double(end - start)
            * Double(numerator)
            / Double(denominator)
            / 1_000_000_000
    }
}

/// Lock-free health state shared by the render callback and the main-thread
/// watchdog. It deliberately starts without a timestamp: the watchdog is
/// seeded immediately before `AudioOutputUnitStart`, after setup has finished.
final class AudioRenderHealthState: @unchecked Sendable {
    /// A single Core Audio render error can be transient during device churn.
    /// Three back-to-back failures still surface a persistent failure quickly.
    static let terminalConsecutiveFailureThreshold: UInt64 = 3

    private let lastCallbackTickStorage = Atomic<UInt64>(0)
    private let lastRenderErrorStorage = Atomic<Int64>(0)
    private let consecutiveRenderFailureCountStorage = Atomic<UInt64>(0)

    var lastCallbackTick: UInt64 {
        lastCallbackTickStorage.load(ordering: .acquiring)
    }

    var lastRenderError: OSStatus? {
        let value = lastRenderErrorStorage.load(ordering: .relaxed)
        return value == 0 ? nil : OSStatus(value)
    }

    var consecutiveRenderFailureCount: UInt64 {
        consecutiveRenderFailureCountStorage.load(ordering: .acquiring)
    }

    var terminalRenderError: OSStatus? {
        guard consecutiveRenderFailureCount
                >= Self.terminalConsecutiveFailureThreshold
        else {
            return nil
        }
        return lastRenderError
    }

    func resetForAudioUnitStart(at tick: UInt64 = mach_continuous_time()) {
        lastCallbackTickStorage.store(tick, ordering: .releasing)
        consecutiveRenderFailureCountStorage.store(0, ordering: .releasing)
        lastRenderErrorStorage.store(0, ordering: .releasing)
    }

    @inline(__always)
    func recordCallback(at tick: UInt64 = mach_continuous_time()) {
        lastCallbackTickStorage.store(tick, ordering: .relaxed)
    }

    @inline(__always)
    func recordRenderSuccess() {
        consecutiveRenderFailureCountStorage.store(0, ordering: .relaxed)
        lastRenderErrorStorage.store(0, ordering: .relaxed)
    }

    @inline(__always)
    func recordRenderFailure(_ status: OSStatus) {
        lastRenderErrorStorage.store(Int64(status), ordering: .relaxed)
        consecutiveRenderFailureCountStorage.wrappingAdd(1, ordering: .releasing)
    }
}

/// Refcon owned by one active AudioUnit. The render callback touches only this
/// object: one AudioUnitRender call, preallocated buffer metadata, and atomics.
final class RealtimeAudioRenderContext: @unchecked Sendable {
    let ring: AudioSPSCRing

    private let unit: AudioUnit
    private let claimedBufferList: PlanarAudioBufferList
    private let discardBufferList: PlanarAudioBufferList
    private let timebase: AudioMachTimebase
    private let healthState = AudioRenderHealthState()
    private let callbackCounter = Atomic<UInt64>(0)
    private let oversizedCallbackCounter = Atomic<UInt64>(0)

    init(
        unit: AudioUnit,
        ring: AudioSPSCRing,
        channels: Int,
        maximumFrames: Int
    ) {
        self.unit = unit
        self.ring = ring
        claimedBufferList = PlanarAudioBufferList(
            channels: channels,
            maximumFrames: maximumFrames,
            ownsSampleStorage: false
        )
        discardBufferList = PlanarAudioBufferList(
            channels: channels,
            maximumFrames: maximumFrames,
            ownsSampleStorage: true
        )
        timebase = AudioMachTimebase()
    }

    var callbackCount: UInt64 {
        callbackCounter.load(ordering: .relaxed)
    }

    var terminalRenderError: OSStatus? {
        healthState.terminalRenderError
    }

    var oversizedCallbackCount: UInt64 {
        oversizedCallbackCounter.load(ordering: .relaxed)
    }

    func secondsSinceLastCallback(now: UInt64 = mach_continuous_time()) -> TimeInterval {
        let lastCallbackTick = healthState.lastCallbackTick
        guard lastCallbackTick > 0 else { return 0 }
        return timebase.seconds(
            from: lastCallbackTick,
            to: now
        )
    }

    func resetCallbackWatchdogForAudioUnitStart() {
        healthState.resetForAudioUnitStart()
    }

    @inline(__always)
    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        healthState.recordCallback()
        callbackCounter.wrappingAdd(1, ordering: .relaxed)

        guard frameCount <= UInt32(ring.maxFrames) else {
            oversizedCallbackCounter.wrappingAdd(1, ordering: .relaxed)
            healthState.recordRenderFailure(kAudioUnitErr_TooManyFramesToProcess)
            return kAudioUnitErr_TooManyFramesToProcess
        }

        if let slot = ring.tryClaimProducer(frameCount: Int(frameCount)) {
            claimedBufferList.target(slot)
            let status = AudioUnitRender(
                unit,
                flags,
                timeStamp,
                busNumber,
                frameCount,
                claimedBufferList.pointer
            )
            if status == noErr {
                healthState.recordRenderSuccess()
                _ = ring.publish(slot)
            } else {
                _ = ring.cancelProducerClaim(slot)
                healthState.recordRenderFailure(status)
            }
            return status
        }

        discardBufferList.prepareOwned(frameCount: Int(frameCount))
        let status = AudioUnitRender(
            unit,
            flags,
            timeStamp,
            busNumber,
            frameCount,
            discardBufferList.pointer
        )
        if status == noErr {
            healthState.recordRenderSuccess()
        } else {
            healthState.recordRenderFailure(status)
        }
        return status
    }
}

private final class AudioCaptureCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<AudioCaptureMetrics, Error>?
    private var waiters: [CheckedContinuation<AudioCaptureMetrics, Error>] = []

    func resolve(_ result: Result<AudioCaptureMetrics, Error>) {
        let continuations: [CheckedContinuation<AudioCaptureMetrics, Error>]
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        continuations = waiters
        waiters.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    func value() async throws -> AudioCaptureMetrics {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

final class AudioCaptureRuntime: @unchecked Sendable {
    private enum RequestedMode {
        static let running: UInt8 = 0
        static let drain: UInt8 = 1
        static let cancel: UInt8 = 2
    }

    let renderContext: RealtimeAudioRenderContext
    let processor: AudioCaptureProcessor

    private let ring: AudioSPSCRing
    private let completion = AudioCaptureCompletion()
    private let requestedMode = Atomic<UInt8>(RequestedMode.running)
    private let consumerQueue = DispatchQueue(
        label: "com.natemunk.LocalDictation.audio-consumer",
        qos: .userInitiated
    )
    private let failureLock = NSLock()
    private var storedFailureDescription: String?

    init(
        renderContext: RealtimeAudioRenderContext,
        processor: AudioCaptureProcessor
    ) {
        self.renderContext = renderContext
        self.processor = processor
        ring = renderContext.ring
    }

    var processingFailureDescription: String? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return storedFailureDescription
    }

    func startConsumer() {
        consumerQueue.async { [self] in consumeUntilTerminalMode() }
    }

    func requestDrain() {
        ring.stop()
        requestedMode.store(RequestedMode.drain, ordering: .releasing)
    }

    func requestCancel() {
        ring.stop()
        requestedMode.store(RequestedMode.cancel, ordering: .releasing)
    }

    func waitForCompletion() async throws -> AudioCaptureMetrics {
        try await completion.value()
    }

    private func consumeUntilTerminalMode() {
        var channelPointers = [UnsafeMutablePointer<Float>](
            repeating: UnsafeMutablePointer<Float>.allocate(capacity: 1),
            count: ring.channels
        )
        // Replace every repeated placeholder before use, then release the one
        // allocation that supplied the placeholder value.
        let placeholder = channelPointers[0]
        defer { placeholder.deallocate() }

        while true {
            let mode = requestedMode.load(ordering: .acquiring)
            if mode == RequestedMode.cancel {
                while let slot = ring.tryClaimConsumer() { _ = ring.release(slot) }
                processor.cancel()
                completion.resolve(.failure(CancellationError()))
                return
            }

            if let slot = ring.tryClaimConsumer() {
                for channel in 0..<ring.channels {
                    channelPointers[channel] = UnsafeMutablePointer(
                        mutating: slot.channel(channel).baseAddress!
                    )
                }
                do {
                    try channelPointers.withUnsafeBufferPointer { pointers in
                        try processor.process(
                            frameCount: slot.frameCount,
                            sourceChannels: pointers
                        )
                    }
                    _ = ring.release(slot)
                } catch {
                    _ = ring.release(slot)
                    ring.stop()
                    processor.cancel()
                    storeFailure(error.localizedDescription)
                    completion.resolve(.failure(error))
                    return
                }
                continue
            }

            if mode == RequestedMode.drain, ring.isDrained {
                do {
                    completion.resolve(.success(try processor.finish()))
                } catch {
                    storeFailure(error.localizedDescription)
                    completion.resolve(.failure(error))
                }
                return
            }

            // A 2 ms idle poll avoids a 2 kHz spin while adding at most about
            // 2 ms to an otherwise-idle drain request.
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private func storeFailure(_ description: String) {
        failureLock.lock()
        storedFailureDescription = description
        failureLock.unlock()
    }
}
