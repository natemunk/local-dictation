@preconcurrency import AVFoundation
import Foundation

enum RemoteAudioNormalizerError: Error, Equatable, Sendable {
    case unsupportedInput
    case emptyAudio
    case durationTooLong
    case outputFileCreationFailed
    case conversionFailed
}

struct NormalizedRemoteAudio: Sendable {
    let inputURL: URL
    let wavURL: URL
    let durationSeconds: TimeInterval

    func removeFiles(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: inputURL)
        try? fileManager.removeItem(at: wavURL)
    }
}

actor RemoteAudioNormalizer {
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func normalize(_ request: IPhoneTranscriptionRequest) throws -> NormalizedRemoteAudio {
        guard !request.audio.isEmpty else { throw RemoteAudioNormalizerError.emptyAudio }
        let extensionName = Self.fileExtension(for: request.mediaType)
        let base = "local-dictation-iphone-\(request.requestID.uuidString.lowercased())"
        let inputURL = temporaryDirectory.appendingPathComponent("\(base).\(extensionName)")
        let wavURL = temporaryDirectory.appendingPathComponent("\(base)-16k.wav")

        do {
            try request.audio.write(to: inputURL, options: [.atomic])
            let input: AVAudioFile
            do {
                input = try AVAudioFile(forReading: inputURL)
            } catch {
                throw RemoteAudioNormalizerError.unsupportedInput
            }
            let duration = input.processingFormat.sampleRate > 0
                ? TimeInterval(input.length) / input.processingFormat.sampleRate
                : 0
            guard duration > 0 else { throw RemoteAudioNormalizerError.emptyAudio }
            guard duration <= IPhoneTranscriptionRequest.maximumDurationSeconds else {
                throw RemoteAudioNormalizerError.durationTooLong
            }

            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) else {
                throw RemoteAudioNormalizerError.unsupportedInput
            }

            guard let fileFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            ) else {
                throw RemoteAudioNormalizerError.conversionFailed
            }
            let output: AVAudioFile
            do {
                output = try AVAudioFile(
                    forWriting: wavURL,
                    settings: fileFormat.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                throw RemoteAudioNormalizerError.outputFileCreationFailed
            }
            do {
                try Self.convert(
                    input: input,
                    output: output,
                    outputFormat: outputFormat
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw RemoteAudioNormalizerError.conversionFailed
            }
            return NormalizedRemoteAudio(
                inputURL: inputURL,
                wavURL: wavURL,
                durationSeconds: duration
            )
        } catch {
            try? fileManager.removeItem(at: inputURL)
            try? fileManager.removeItem(at: wavURL)
            throw error
        }
    }

    private static func convert(
        input: AVAudioFile,
        output: AVAudioFile,
        outputFormat: AVAudioFormat
    ) throws {
        let inputFormat = input.processingFormat
        let maximumFrames = 8_192
        let chunks = BoundedAudioChunkStream(bufferingLimit: 1)
        let processor = try AudioCaptureProcessor(
            inputFormat: inputFormat,
            outputFormat: outputFormat,
            maximumInputFrames: maximumFrames,
            audioFile: output,
            chunkSource: chunks
        )

        while input.framePosition < input.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(maximumFrames)
            ) else { throw RemoteAudioNormalizerError.conversionFailed }
            try input.read(into: buffer, frameCount: buffer.frameCapacity)
            guard buffer.frameLength > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw RemoteAudioNormalizerError.unsupportedInput
            }
            let channelBuffer = UnsafeBufferPointer(
                start: channels,
                count: Int(inputFormat.channelCount)
            )
            try processor.process(
                frameCount: Int(buffer.frameLength),
                sourceChannels: channelBuffer
            )
        }
        _ = try processor.finish()
    }

    private static func fileExtension(for mediaType: String) -> String {
        switch mediaType.lowercased() {
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        default: "m4a"
        }
    }
}
