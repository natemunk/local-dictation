import AVFoundation
import Foundation
import Synchronization

enum AudioCaptureProcessingError: Error, LocalizedError, Equatable {
    case invalidSourceBuffer
    case converterCreationFailed
    case converterFailed(String)
    case converterMadeNoProgress
    case sampleCountMismatch(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidSourceBuffer:
            "The captured audio block did not match the configured input format."
        case .converterCreationFailed:
            "The native microphone format could not be converted to 16 kHz mono."
        case .converterFailed(let message):
            "Audio conversion failed: \(message)"
        case .converterMadeNoProgress:
            "Audio conversion stopped making progress."
        case .sampleCountMismatch(let expected, let actual):
            "Audio conversion produced \(actual) samples; expected \(expected)."
        }
    }
}

struct AudioCaptureMetrics: Equatable, Sendable {
    let peakRMS: Float
    let meanRMS: Float
    let acceptedInputFrames: Int64
    let emittedOutputFrames: Int64
    let droppedStreamingChunks: Int
}

final class AudioCaptureTelemetry: @unchecked Sendable {
    private let levelBits = Atomic<UInt32>(0)
    private let outputFrames = Atomic<Int64>(0)

    var currentLevel: Float {
        Float(bitPattern: levelBits.load(ordering: .relaxed))
    }

    var emittedOutputFrames: Int64 {
        outputFrames.load(ordering: .relaxed)
    }

    func publish(level: Float, emittedFrames: Int64) {
        levelBits.store(level.bitPattern, ordering: .relaxed)
        outputFrames.store(emittedFrames, ordering: .relaxed)
    }

    func reset() {
        levelBits.store(Float.zero.bitPattern, ordering: .relaxed)
        outputFrames.store(0, ordering: .relaxed)
    }
}

/// Consumer-queue-only conversion, metering, WAV writing, and streaming.
/// No method on this type is called by the Core Audio render callback.
final class AudioCaptureProcessor: @unchecked Sendable {
    let telemetry: AudioCaptureTelemetry

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let maximumInputFrames: Int
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let converter: AVAudioConverter
    private let chunkSource: BoundedAudioChunkStream
    private var audioFile: AVAudioFile?
    private var accounting: AudioFrameAccounting
    private var sumOfSquares: Double = 0
    private var totalMeteredSamples: Int64 = 0
    private var storedPeakRMS: Float = 0
    private var isFinished = false

    init(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        maximumInputFrames: Int,
        audioFile: AVAudioFile,
        chunkSource: BoundedAudioChunkStream,
        telemetry: AudioCaptureTelemetry = AudioCaptureTelemetry()
    ) throws {
        precondition(maximumInputFrames > 0)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(maximumInputFrames)
        ) else {
            throw AudioCaptureProcessingError.invalidSourceBuffer
        }
        let outputCapacity = AudioFrameSizing.convertedCapacity(
            inputFrameCapacity: maximumInputFrames,
            inputSampleRate: inputFormat.sampleRate,
            outputSampleRate: outputFormat.sampleRate
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(outputCapacity)
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw AudioCaptureProcessingError.converterCreationFailed
        }

        if inputFormat.channelCount > 1, outputFormat.channelCount == 1 {
            converter.channelMap = [0]
        }
        converter.primeMethod = .none

        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.maximumInputFrames = maximumInputFrames
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
        self.converter = converter
        self.audioFile = audioFile
        self.chunkSource = chunkSource
        self.telemetry = telemetry
        accounting = AudioFrameAccounting(
            inputSampleRate: inputFormat.sampleRate,
            outputSampleRate: outputFormat.sampleRate
        )
        telemetry.reset()
    }

    func process(
        frameCount: Int,
        sourceChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>
    ) throws {
        guard !isFinished,
              frameCount > 0,
              frameCount <= maximumInputFrames,
              sourceChannels.count >= Int(inputFormat.channelCount),
              let inputChannels = inputBuffer.floatChannelData
        else {
            throw AudioCaptureProcessingError.invalidSourceBuffer
        }

        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<Int(inputFormat.channelCount) {
            inputChannels[channel].update(
                from: sourceChannels[channel],
                count: frameCount
            )
        }

        meter(channel: sourceChannels[0], frameCount: frameCount)
        accounting.acceptInput(frames: frameCount)
        try convertOneInputBuffer()
    }

    func finish() throws -> AudioCaptureMetrics {
        guard !isFinished else { return metrics }
        do {
            try flushConverter()
            guard accounting.pendingOutputFrames == 0 else {
                throw AudioCaptureProcessingError.sampleCountMismatch(
                    expected: accounting.expectedOutputFrames,
                    actual: accounting.emittedOutputFrames
                )
            }
            isFinished = true
            audioFile = nil
            chunkSource.finish()
            telemetry.publish(level: 0, emittedFrames: accounting.emittedOutputFrames)
            return metrics
        } catch {
            isFinished = true
            audioFile = nil
            chunkSource.cancel()
            telemetry.publish(level: 0, emittedFrames: accounting.emittedOutputFrames)
            throw error
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        audioFile = nil
        chunkSource.cancel()
        telemetry.publish(level: 0, emittedFrames: accounting.emittedOutputFrames)
    }

    var metrics: AudioCaptureMetrics {
        AudioCaptureMetrics(
            peakRMS: storedPeakRMS,
            meanRMS: totalMeteredSamples > 0
                ? Float(sqrt(sumOfSquares / Double(totalMeteredSamples)))
                : 0,
            acceptedInputFrames: accounting.acceptedInputFrames,
            emittedOutputFrames: accounting.emittedOutputFrames,
            droppedStreamingChunks: chunkSource.droppedChunkCount
        )
    }

    private func meter(channel: UnsafeMutablePointer<Float>, frameCount: Int) {
        var blockSquares: Double = 0
        for index in 0..<frameCount {
            let sample = Double(channel[index])
            blockSquares += sample * sample
        }
        sumOfSquares += blockSquares
        totalMeteredSamples += Int64(frameCount)

        let rms = Float(sqrt(blockSquares / Double(frameCount)))
        storedPeakRMS = max(storedPeakRMS, rms)
        let decibels = 20 * log10(max(rms, 0.000_001))
        let normalized = max(0, min(1, (decibels + 40) / 40))
        telemetry.publish(
            level: normalized,
            emittedFrames: accounting.emittedOutputFrames
        )
    }

    private func convertOneInputBuffer() throws {
        var suppliedInput = false
        var iterations = 0

        while true {
            iterations += 1
            guard iterations <= 32 else {
                throw AudioCaptureProcessingError.converterMadeNoProgress
            }
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { [inputBuffer] _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw AudioCaptureProcessingError.converterFailed(
                    conversionError.localizedDescription
                )
            }
            try writeOutputBuffer()

            switch status {
            case .haveData:
                guard outputBuffer.frameLength > 0 else {
                    throw AudioCaptureProcessingError.converterMadeNoProgress
                }
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw AudioCaptureProcessingError.converterFailed(
                    "AVAudioConverter returned an error without NSError details"
                )
            @unknown default:
                throw AudioCaptureProcessingError.converterFailed(
                    "AVAudioConverter returned an unknown status"
                )
            }
        }
    }

    private func flushConverter() throws {
        var iterations = 0
        while accounting.pendingOutputFrames > 0 {
            iterations += 1
            guard iterations <= 64 else {
                throw AudioCaptureProcessingError.converterMadeNoProgress
            }
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }

            if let conversionError {
                throw AudioCaptureProcessingError.converterFailed(
                    conversionError.localizedDescription
                )
            }
            let framesBeforeWrite = accounting.emittedOutputFrames
            try writeOutputBuffer()
            let madeProgress = accounting.emittedOutputFrames > framesBeforeWrite

            if status == .error {
                throw AudioCaptureProcessingError.converterFailed(
                    "AVAudioConverter returned an error while flushing"
                )
            }
            if !madeProgress, (status == .endOfStream || status == .inputRanDry) {
                break
            }
            if !madeProgress, outputBuffer.frameLength == 0 {
                throw AudioCaptureProcessingError.converterMadeNoProgress
            }
        }
    }

    private func writeOutputBuffer() throws {
        let available = min(
            Int64(outputBuffer.frameLength),
            accounting.pendingOutputFrames
        )
        guard available > 0 else { return }
        outputBuffer.frameLength = AVAudioFrameCount(available)

        do {
            guard let audioFile else {
                throw AudioCaptureProcessingError.converterFailed(
                    "The WAV file was closed before conversion completed"
                )
            }
            try audioFile.write(from: outputBuffer)
        } catch {
            if let processingError = error as? AudioCaptureProcessingError {
                throw processingError
            }
            throw AudioCaptureProcessingError.converterFailed(
                "WAV write failed: \(error.localizedDescription)"
            )
        }

        guard accounting.recordEmission(frames: Int(available)) else {
            throw AudioCaptureProcessingError.sampleCountMismatch(
                expected: accounting.expectedOutputFrames,
                actual: accounting.emittedOutputFrames + available
            )
        }
        if let samples = outputBuffer.floatChannelData?[0] {
            _ = chunkSource.yield(
                copying: UnsafeBufferPointer(start: samples, count: Int(available)),
                sampleRate: Int(outputFormat.sampleRate)
            )
        }
        telemetry.publish(
            level: telemetry.currentLevel,
            emittedFrames: accounting.emittedOutputFrames
        )
    }
}
