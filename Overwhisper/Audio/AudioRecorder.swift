import AVFoundation
import Foundation
import Combine
import CoreAudio
import AudioToolbox

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

@MainActor
class AudioDeviceManager: ObservableObject {
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var defaultInputDeviceID: AudioDeviceID?

    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    init() {
        refreshDevices()
        startMonitoring()
    }

    func device(forUID uid: String) -> AudioInputDevice? {
        inputDevices.first { $0.uid == uid }
    }

    var defaultInputDeviceName: String? {
        guard let defaultID = defaultInputDeviceID else { return nil }
        return inputDevices.first { $0.id == defaultID }?.name
    }

    func shutdown() {
        stopMonitoring()
    }

    func refreshDevices() {
        let devices = AudioDeviceManager.fetchInputDevices()
        let defaultID = AudioDeviceManager.defaultInputDeviceID()

        inputDevices = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        defaultInputDeviceID = defaultID
    }

    private func startMonitoring() {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }

        let defaultDeviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDevices()
            }
        }

        self.devicesListener = devicesListener
        self.defaultDeviceListener = defaultDeviceListener

        AudioObjectAddPropertyListenerBlock(systemObjectID, &devicesAddress, DispatchQueue.main, devicesListener)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &defaultDeviceAddress, DispatchQueue.main, defaultDeviceListener)
    }

    private func stopMonitoring() {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if let devicesListener {
            AudioObjectRemovePropertyListenerBlock(systemObjectID, &devicesAddress, DispatchQueue.main, devicesListener)
        }

        if let defaultDeviceListener {
            AudioObjectRemovePropertyListenerBlock(systemObjectID, &defaultDeviceAddress, DispatchQueue.main, defaultDeviceListener)
        }
    }

    private static func fetchInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard deviceHasInput(deviceID) else { return nil }
            guard let name = deviceName(deviceID),
                  let uid = deviceUID(deviceID) else {
                return nil
            }
            return AudioInputDevice(id: deviceID, name: name, uid: uid)
        }
    }

    nonisolated static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceID)
        guard status == noErr else { return nil }
        return deviceID
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // CoreAudio writes a CFStringRef pointer. Store that pointer as
        // `Unmanaged` so Swift does not form an UnsafeMutableRawPointer to a
        // strong object-reference variable (which is both warned about and can
        // violate ARC's representation assumptions).
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name)
        guard status == noErr, let name else { return nil }
        return name.takeUnretainedValue() as String
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &uid)
        guard status == noErr, let uid else { return nil }
        return uid.takeUnretainedValue() as String
    }

    private static func deviceHasInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return false
        }
        guard dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return false
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        bufferListPointer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(dataSize))
        defer { bufferListPointer.deallocate() }

        var dataSizeCopy = dataSize
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSizeCopy,
            bufferListPointer
        )
        guard status == noErr else { return false }

        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }
}

@MainActor
final class AudioRecorder: ObservableObject {
    private var inputUnit: AudioUnit?
    private var captureRuntime: AudioCaptureRuntime?
    private var audioChunkSource: BoundedAudioChunkStream?
    private var recordingURL: URL?
    private var selectedInputDeviceID: AudioDeviceID?
    private let audioChunkBufferingLimit: Int
    private let realtimeRingCapacity: Int
    private var healthTimer: Timer?
    private var callbackLossHandled = false
    private var captureFailureHandled = false

    @Published var currentLevel: Float = 0
    @Published var isRecording = false
    @Published private(set) var microphoneDisconnected = false

    private(set) var peakRMS: Float = 0
    private(set) var meanRMS: Float = 0
    private(set) var droppedAudioChunkCount = 0
    private(set) var realtimeOverflowCount: UInt64 = 0
    private(set) var oversizedCallbackCount: UInt64 = 0

    var onCallbackLoss: ((AudioCallbackLossAction) -> Void)?
    var onCaptureFailure: ((String) -> Void)?

    private let sampleRate: Double = 16_000
    private let channels: AVAudioChannelCount = 1

    init(
        audioChunkBufferingLimit: Int = 128,
        realtimeRingCapacity: Int = 64
    ) {
        precondition(audioChunkBufferingLimit > 0)
        precondition(realtimeRingCapacity > 1)
        self.audioChunkBufferingLimit = audioChunkBufferingLimit
        self.realtimeRingCapacity = realtimeRingCapacity
    }

    deinit {
        healthTimer?.invalidate()
        if let unit = inputUnit {
            _ = AudioOutputUnitStop(unit)
            _ = AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        captureRuntime?.requestCancel()
    }

    func setInputDevice(_ device: AudioInputDevice?) {
        selectedInputDeviceID = device?.id
    }

    @discardableResult
    func startRecording() throws -> AsyncStream<AudioChunk> {
        if isRecording {
            guard let audioChunkSource else {
                throw AudioRecorderError.deviceConfigurationFailed
            }
            return audioChunkSource.stream
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined, .denied, .restricted:
            throw AudioRecorderError.noPermission
        @unknown default:
            throw AudioRecorderError.noPermission
        }

        resetPublishedMetrics()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "local_dictation_recording_\(UUID().uuidString).wav"
        )
        recordingURL = url

        do {
            guard let requestedDeviceID = selectedInputDeviceID
                    ?? AudioDeviceManager.defaultInputDeviceID()
            else {
                throw AudioRecorderError.deviceConfigurationFailed
            }

            let unit: AudioUnit
            let clientFormat: AVAudioFormat
            let maximumFrames: Int
            let activeDeviceID: AudioDeviceID
            do {
                (unit, clientFormat, maximumFrames) = try makeInputUnit(
                    deviceID: requestedDeviceID
                )
                activeDeviceID = requestedDeviceID
            } catch {
                guard let fallback = AudioDeviceManager.defaultInputDeviceID(),
                      fallback != requestedDeviceID
                else { throw error }
                AppLogger.audio.error(
                    "Input device \(requestedDeviceID) failed to open; using the system default"
                )
                selectedInputDeviceID = nil
                (unit, clientFormat, maximumFrames) = try makeInputUnit(
                    deviceID: fallback
                )
                activeDeviceID = fallback
            }
            inputUnit = unit

            guard let canonicalFormat = AudioFormatFactory.noninterleavedFloat32(
                sampleRate: sampleRate,
                channels: channels
            ) else {
                throw AudioRecorderError.invalidFormat
            }
            let wavFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: true
            )!
            let audioFile = try AVAudioFile(
                forWriting: url,
                settings: wavFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let chunkSource = BoundedAudioChunkStream(
                bufferingLimit: audioChunkBufferingLimit
            )
            let processor = try AudioCaptureProcessor(
                inputFormat: clientFormat,
                outputFormat: canonicalFormat,
                maximumInputFrames: maximumFrames,
                audioFile: audioFile,
                chunkSource: chunkSource
            )
            let ring = AudioSPSCRing(
                capacity: realtimeRingCapacity,
                maxFrames: maximumFrames,
                channels: Int(clientFormat.channelCount)
            )
            let renderContext = RealtimeAudioRenderContext(
                unit: unit,
                ring: ring,
                channels: Int(clientFormat.channelCount),
                maximumFrames: maximumFrames
            )
            let runtime = AudioCaptureRuntime(
                renderContext: renderContext,
                processor: processor
            )
            captureRuntime = runtime
            audioChunkSource = chunkSource

            var callback = AURenderCallbackStruct(
                inputProc: { reference, flags, timestamp, bus, frames, _ in
                    let context = Unmanaged<RealtimeAudioRenderContext>
                        .fromOpaque(reference)
                        .takeUnretainedValue()
                    return context.render(
                        flags: flags,
                        timeStamp: timestamp,
                        busNumber: bus,
                        frameCount: frames
                    )
                },
                inputProcRefCon: Unmanaged.passUnretained(renderContext).toOpaque()
            )
            var status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
            guard status == noErr else {
                throw AudioRecorderError.deviceConfigurationFailed
            }

            status = AudioUnitInitialize(unit)
            guard status == noErr else {
                throw AudioRecorderError.deviceConfigurationFailed
            }

            runtime.startConsumer()
            status = AudioOutputUnitStart(unit)
            guard status == noErr else {
                throw AudioRecorderError.deviceConfigurationFailed
            }

            isRecording = true
            startHealthMonitoring()
            let nativeRate = clientFormat.sampleRate
            let nativeChannels = clientFormat.channelCount
            AppLogger.audio.info(
                "Recording start — device id \(activeDeviceID, privacy: .public), \(nativeRate, privacy: .public) Hz, \(nativeChannels, privacy: .public) ch, max slice \(maximumFrames, privacy: .public)"
            )
            return chunkSource.stream
        } catch {
            cleanupFailedStart()
            throw error
        }
    }

    func stopRecording() async throws -> URL {
        guard isRecording,
              let url = recordingURL,
              let runtime = captureRuntime
        else {
            throw AudioRecorderError.notRecording
        }

        stopHealthMonitoring()
        stopAndDisposeInputUnit()
        runtime.requestDrain()

        do {
            let metrics = try await runtime.waitForCompletion()
            if captureRuntime === runtime {
                apply(metrics: metrics, runtime: runtime)
                finishRuntimeState(ownedBy: runtime)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AudioRecorderError.failedToCreateFile
            }
            if recordingURL == url { recordingURL = nil }
            return url
        } catch {
            finishRuntimeState(ownedBy: runtime)
            try? FileManager.default.removeItem(at: url)
            if recordingURL == url { recordingURL = nil }
            throw error
        }
    }

    func cancelRecording() {
        guard captureRuntime != nil || inputUnit != nil || recordingURL != nil else {
            return
        }

        stopHealthMonitoring()
        stopAndDisposeInputUnit()
        let runtime = captureRuntime
        let url = recordingURL
        runtime?.requestCancel()
        finishRuntimeState(ownedBy: runtime)
        if recordingURL == url { recordingURL = nil }

        if let runtime {
            Task {
                _ = try? await runtime.waitForCompletion()
                if let url { try? FileManager.default.removeItem(at: url) }
            }
        } else if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func resetAudioEngine() {
        cancelRecording()
    }

    private func resetPublishedMetrics() {
        peakRMS = 0
        meanRMS = 0
        droppedAudioChunkCount = 0
        realtimeOverflowCount = 0
        oversizedCallbackCount = 0
        currentLevel = 0
        microphoneDisconnected = false
        callbackLossHandled = false
        captureFailureHandled = false
    }

    private func startHealthMonitoring() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCaptureHealth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func stopHealthMonitoring() {
        healthTimer?.invalidate()
        healthTimer = nil
        currentLevel = 0
        microphoneDisconnected = false
    }

    private func pollCaptureHealth() {
        guard isRecording, let runtime = captureRuntime else { return }

        if !captureFailureHandled,
           let failure = runtime.processingFailureDescription {
            captureFailureHandled = true
            onCaptureFailure?(failure)
            return
        }
        if !captureFailureHandled,
           let renderError = runtime.renderContext.lastRenderError {
            captureFailureHandled = true
            onCaptureFailure?(
                "The microphone render callback failed (OSStatus \(renderError))."
            )
            return
        }
        if !captureFailureHandled,
           runtime.renderContext.oversizedCallbackCount > 0 {
            captureFailureHandled = true
            onCaptureFailure?(
                "The microphone produced a block larger than its declared maximum."
            )
            return
        }

        let health = AudioCallbackHealthPolicy.evaluate(
            secondsSinceLastCallback: runtime.renderContext.secondsSinceLastCallback(),
            capturedOutputFrames: runtime.processor.telemetry.emittedOutputFrames
        )
        currentLevel = health.shouldZeroMeter
            ? 0
            : runtime.processor.telemetry.currentLevel
        microphoneDisconnected = health.isDisconnected

        guard !callbackLossHandled, health.lossAction != .none else { return }
        callbackLossHandled = true
        onCallbackLoss?(health.lossAction)
    }

    private func apply(
        metrics: AudioCaptureMetrics,
        runtime: AudioCaptureRuntime
    ) {
        peakRMS = metrics.peakRMS
        meanRMS = metrics.meanRMS
        realtimeOverflowCount = runtime.renderContext.ring.overflowCount
        oversizedCallbackCount = runtime.renderContext.oversizedCallbackCount
        let totalDrops = UInt64(metrics.droppedStreamingChunks)
            &+ realtimeOverflowCount
        droppedAudioChunkCount = totalDrops > UInt64(Int.max)
            ? Int.max
            : Int(totalDrops)
    }

    private func finishRuntimeState(ownedBy runtime: AudioCaptureRuntime?) {
        if let runtime {
            guard captureRuntime === runtime else { return }
        } else {
            guard captureRuntime == nil else { return }
        }
        captureRuntime = nil
        audioChunkSource = nil
        isRecording = false
        currentLevel = 0
        microphoneDisconnected = false
    }

    private func cleanupFailedStart() {
        stopHealthMonitoring()
        stopAndDisposeInputUnit()
        let runtime = captureRuntime
        let url = recordingURL
        runtime?.requestCancel()
        finishRuntimeState(ownedBy: runtime)
        if recordingURL == url { recordingURL = nil }

        if let runtime {
            Task {
                _ = try? await runtime.waitForCompletion()
                if let url { try? FileManager.default.removeItem(at: url) }
            }
        } else if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func stopAndDisposeInputUnit() {
        guard let unit = inputUnit else { return }
        _ = AudioOutputUnitStop(unit)
        _ = AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        inputUnit = nil
    }

    private func makeInputUnit(
        deviceID: AudioDeviceID
    ) throws -> (AudioUnit, AVAudioFormat, Int) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioRecorderError.deviceConfigurationFailed
        }

        var optionalUnit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &optionalUnit)
        guard status == noErr, let unit = optionalUnit else {
            throw AudioRecorderError.deviceConfigurationFailed
        }

        func fail(_ message: String) -> AudioRecorderError {
            AppLogger.audio.error("makeInputUnit: \(message, privacy: .public)")
            AudioComponentInstanceDispose(unit)
            return .deviceConfigurationFailed
        }

        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            flagSize
        )
        guard status == noErr else {
            throw fail("EnableIO(input) failed: \(status)")
        }

        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            flagSize
        )
        guard status == noErr else {
            throw fail("DisableIO(output) failed: \(status)")
        }

        var device = deviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw fail("Set CurrentDevice failed: \(status)")
        }

        var hardwareFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &hardwareFormat,
            &formatSize
        )
        guard status == noErr,
              hardwareFormat.mSampleRate > 0,
              hardwareFormat.mChannelsPerFrame > 0
        else {
            throw fail("Get hardware format failed: \(status)")
        }

        guard let clientFormat = AudioFormatFactory.noninterleavedFloat32(
            sampleRate: hardwareFormat.mSampleRate,
            channels: hardwareFormat.mChannelsPerFrame
        ) else {
            throw fail(
                "Unsupported client format: \(hardwareFormat.mSampleRate) Hz, "
                    + "\(hardwareFormat.mChannelsPerFrame) ch"
            )
        }
        var clientDescription = clientFormat.streamDescription.pointee
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &clientDescription,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw fail("Set client format failed: \(status)")
        }

        var maximumFrames: UInt32 = 0
        var maximumFramesSize = UInt32(MemoryLayout<UInt32>.size)
        status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFrames,
            &maximumFramesSize
        )
        guard status == noErr, maximumFrames > 0 else {
            throw fail("Get maximum frames per slice failed: \(status)")
        }

        return (unit, clientFormat, Int(maximumFrames))
    }
}

enum AudioRecorderError: LocalizedError {
    case failedToCreateFile
    case invalidFormat
    case converterCreationFailed
    case notRecording
    case noPermission
    case deviceConfigurationFailed

    var errorDescription: String? {
        switch self {
        case .failedToCreateFile:
            return "Failed to create audio file"
        case .invalidFormat:
            return "Invalid audio format"
        case .converterCreationFailed:
            return "Failed to create audio converter"
        case .notRecording:
            return "Not currently recording"
        case .noPermission:
            return "Microphone permission not granted"
        case .deviceConfigurationFailed:
            return "Failed to configure input device"
        }
    }
}
