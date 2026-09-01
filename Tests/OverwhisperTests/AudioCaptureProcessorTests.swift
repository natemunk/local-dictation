import AVFoundation
import Foundation
import Testing
@testable import LocalDictation

@Suite("Audio capture consumer")
struct AudioCaptureProcessorTests {
    @Test("44.1, 48, and 96 kHz inputs produce exact 16 kHz WAV and stream lengths")
    func exactSampleCounts() async throws {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let harness = try ProcessorHarness(sampleRate: rate, channels: 1)
            var remaining = Int(rate)
            while remaining > 0 {
                let frames = min(512, remaining)
                try harness.process(frameCount: frames, values: [0.25])
                remaining -= frames
            }

            let metrics = try harness.processor.finish()
            let chunks = await collect(harness.source.stream)
            let file = try AVAudioFile(forReading: harness.url)

            #expect(metrics.acceptedInputFrames == Int64(rate))
            #expect(metrics.emittedOutputFrames == 16_000)
            #expect(chunks.reduce(0) { $0 + $1.samples.count } == 16_000)
            #expect(file.length == 16_000)
            try? FileManager.default.removeItem(at: harness.url)
        }
    }

    @Test("multichannel capture meters and converts only the primary input channel")
    func primaryChannelIsCanonical() async throws {
        let harness = try ProcessorHarness(sampleRate: 48_000, channels: 4)
        try harness.process(
            frameCount: 4_800,
            values: [0.25, 0.9, -0.8, 0.7]
        )

        let metrics = try harness.processor.finish()
        let chunks = await collect(harness.source.stream)
        let output = chunks.flatMap(\.samples)

        #expect(abs(metrics.meanRMS - 0.25) < 0.000_1)
        #expect(abs(metrics.peakRMS - 0.25) < 0.000_1)
        #expect(output.count == 1_600)
        let outputSum = output.reduce(0.0) { $0 + Double($1) }
        let outputMean = outputSum / Double(output.count)
        #expect(abs(outputMean - 0.25) < 0.01)
        try? FileManager.default.removeItem(at: harness.url)
    }

    private func collect(_ stream: AsyncStream<AudioChunk>) async -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        for await chunk in stream { chunks.append(chunk) }
        return chunks
    }
}

private final class ProcessorHarness {
    let url: URL
    let source: BoundedAudioChunkStream
    let processor: AudioCaptureProcessor
    private let channels: Int

    init(sampleRate: Double, channels: Int) throws {
        self.channels = channels
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-processor-\(UUID().uuidString).wav")
        source = BoundedAudioChunkStream(bufferingLimit: 10_000)

        guard let input = AudioFormatFactory.noninterleavedFloat32(
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels)
        ),
        let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
        else {
            throw AudioCaptureProcessingError.invalidSourceBuffer
        }
        let fileFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        processor = try AudioCaptureProcessor(
            inputFormat: input,
            outputFormat: output,
            maximumInputFrames: 4_800,
            audioFile: file,
            chunkSource: source
        )
    }

    func process(frameCount: Int, values: [Float]) throws {
        precondition(values.count == channels)
        let pointers = values.map { value -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            pointer.initialize(repeating: value, count: frameCount)
            return pointer
        }
        defer {
            for pointer in pointers {
                pointer.deinitialize(count: frameCount)
                pointer.deallocate()
            }
        }
        try pointers.withUnsafeBufferPointer { pointerBuffer in
            try processor.process(
                frameCount: frameCount,
                sourceChannels: pointerBuffer
            )
        }
    }
}
