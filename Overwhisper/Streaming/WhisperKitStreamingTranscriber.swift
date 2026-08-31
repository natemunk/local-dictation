import Foundation
@preconcurrency import WhisperKit

/// Event-driven rolling transcription over WhisperKit's public sample-array API.
///
/// Pinned WhisperKit 0.15.0 cannot safely use its `AudioStreamTranscriber` here:
/// `Core/Audio/AudioStreamTranscriber.swift:73-85` starts
/// `audioProcessor.startRecordingLive` internally and exposes no method that
/// accepts an external sample stream. That would create a second microphone
/// capture. The pinned public alternative is
/// `WhisperKit.swift:885-898`, `transcribe(audioArray:decodeOptions:)`, which
/// explicitly accepts 16 kHz float samples. We call it only after new recorder
/// chunks arrive (never from an idle polling loop) and replace volatile text on
/// every pass. This is rolling re-inference, not cache-aware decoder streaming.
actor WhisperKitStreamingTranscriber: StreamingTranscriber {
    private static let requiredSampleRate = 16_000

    private let model: String?
    private let downloadBase: URL?
    private let modelFolder: String?
    private let computeOptions: ModelComputeOptions
    private let shouldDownload: Bool
    private let decodingOptions: DecodingOptions
    private let inferenceIntervalSamples: Int
    private let requiredSegmentsForConfirmation: Int

    private var whisperKit: WhisperKit?
    private var isPrepared = false

    private var sessionID: UUID?
    private var worker: Task<Void, Never>?
    private var outputContinuation: AsyncStream<TranscriptUpdate>.Continuation?
    private var sessionFailure: StreamingTranscriberError?
    private var lastSequence: Int64?
    private var samples: [Float] = []
    private var lastInferenceSampleCount = 0
    private var confirmedText = ""
    private var volatileText = ""
    private var lastConfirmedSegmentEnd: Float = 0
    private var detectedLanguage: String?

    init(
        model: String? = nil,
        downloadBase: URL? = nil,
        modelFolder: String? = nil,
        computeOptions: ModelComputeOptions = ModelComputeOptions(
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        ),
        download: Bool = true,
        decodingOptions: DecodingOptions = DecodingOptions(
            task: .transcribe,
            temperature: 0,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: false
        ),
        inferenceIntervalSamples: Int = 16_000,
        requiredSegmentsForConfirmation: Int = 2
    ) {
        precondition(inferenceIntervalSamples > 0)
        precondition(requiredSegmentsForConfirmation >= 0)
        self.model = model
        self.downloadBase = downloadBase
        self.modelFolder = modelFolder
        self.computeOptions = computeOptions
        self.shouldDownload = download
        self.decodingOptions = decodingOptions
        self.inferenceIntervalSamples = inferenceIntervalSamples
        self.requiredSegmentsForConfirmation = requiredSegmentsForConfirmation
    }

    init(
        whisperKit: WhisperKit,
        decodingOptions: DecodingOptions = DecodingOptions(
            task: .transcribe,
            temperature: 0,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: false
        ),
        inferenceIntervalSamples: Int = 16_000,
        requiredSegmentsForConfirmation: Int = 2
    ) {
        precondition(inferenceIntervalSamples > 0)
        precondition(requiredSegmentsForConfirmation >= 0)
        self.model = nil
        self.downloadBase = nil
        self.modelFolder = nil
        self.computeOptions = ModelComputeOptions()
        self.shouldDownload = false
        self.decodingOptions = decodingOptions
        self.inferenceIntervalSamples = inferenceIntervalSamples
        self.requiredSegmentsForConfirmation = requiredSegmentsForConfirmation
        self.whisperKit = whisperKit
    }

    func prepare() async throws {
        guard !isPrepared else { return }

        do {
            if let whisperKit {
                switch whisperKit.modelState {
                case .loaded:
                    break
                case .prewarmed:
                    try await whisperKit.loadModels()
                default:
                    try await whisperKit.prewarmModels()
                    try await whisperKit.loadModels()
                }
            } else {
                // Initialization performs specialization and loading only. No
                // audio inference runs until `start` receives enough samples.
                whisperKit = try await WhisperKit(
                    model: model,
                    downloadBase: downloadBase,
                    modelFolder: modelFolder,
                    computeOptions: computeOptions,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: shouldDownload
                )
            }
            isPrepared = true
        } catch {
            throw StreamingTranscriberError.inferenceFailed(
                "WhisperKit preparation failed: \(error.localizedDescription)"
            )
        }
    }

    func start(
        samples: AsyncStream<AudioChunk>
    ) async throws -> AsyncStream<TranscriptUpdate> {
        guard isPrepared, whisperKit != nil else {
            throw StreamingTranscriberError.notPrepared
        }
        guard worker == nil else { throw StreamingTranscriberError.alreadyRunning }

        let id = UUID()
        let pair = AsyncStream<TranscriptUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.onTermination = { [weak self] reason in
            guard case .cancelled = reason else { return }
            Task { await self?.cancel(sessionID: id) }
        }

        resetSessionBuffers()
        sessionID = id
        outputContinuation = pair.continuation
        worker = Task { [weak self] in
            await self?.consume(samples, sessionID: id)
        }
        return pair.stream
    }

    func finish() async throws -> FinalTranscript {
        guard let id = sessionID, let worker else {
            throw StreamingTranscriberError.noActiveSession
        }

        await worker.value
        guard sessionID == id else { throw StreamingTranscriberError.noActiveSession }

        if let sessionFailure {
            closeSession(id: id)
            throw sessionFailure
        }

        do {
            let finalText: String
            if samples.isEmpty {
                finalText = StreamingTranscriptText.join(confirmedText, volatileText)
            } else {
                finalText = try await inferFinalTranscript()
            }

            let final = FinalTranscript(text: finalText, language: detectedLanguage)
            outputContinuation?.yield(
                TranscriptUpdate(finalized: final.text, volatile: "")
            )
            closeSession(id: id)
            return final
        } catch let error as StreamingTranscriberError {
            closeSession(id: id)
            throw error
        } catch {
            let failure = StreamingTranscriberError.inferenceFailed(
                error.localizedDescription
            )
            closeSession(id: id)
            throw failure
        }
    }

    func cancel() async {
        guard let id = sessionID else { return }
        await cancel(sessionID: id)
    }

    private func consume(
        _ chunks: AsyncStream<AudioChunk>,
        sessionID id: UUID
    ) async {
        do {
            for await chunk in chunks {
                try Task.checkCancellation()
                guard sessionID == id else { return }
                try validate(chunk)
                guard !chunk.samples.isEmpty else { continue }

                samples.append(contentsOf: chunk.samples)
                let newSampleCount = samples.count - lastInferenceSampleCount
                guard samples.count >= inferenceIntervalSamples,
                      newSampleCount >= inferenceIntervalSamples
                else {
                    continue
                }

                try await inferUpdate()
                lastInferenceSampleCount = samples.count
            }
        } catch is CancellationError {
            return
        } catch let error as StreamingTranscriberError {
            failSession(error, id: id)
        } catch {
            failSession(.inferenceFailed(error.localizedDescription), id: id)
        }
    }

    private func inferUpdate() async throws {
        guard let whisperKit else { throw StreamingTranscriberError.notPrepared }

        var options = decodingOptions
        options.clipTimestamps = [lastConfirmedSegmentEnd]
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        if let language = results.lazy.map(\.language).first(where: { !$0.isEmpty }) {
            detectedLanguage = language
        }

        let segments = results.flatMap(\.segments)
        let stableCount = max(0, segments.count - requiredSegmentsForConfirmation)
        let stableSegments = segments.prefix(stableCount).filter {
            $0.end > lastConfirmedSegmentEnd + 0.001
        }
        let remainingSegments = segments.suffix(segments.count - stableCount)

        if let lastStable = stableSegments.last {
            confirmedText = StreamingTranscriptText.join(
                confirmedText,
                stableSegments.map(\.text).joined(separator: " ")
            )
            lastConfirmedSegmentEnd = max(lastConfirmedSegmentEnd, lastStable.end)
        }

        let replacement = remainingSegments.map(\.text).joined(separator: " ")
        volatileText = StreamingTranscriptText.normalized(
            segments.isEmpty
                ? results.map(\.text).joined(separator: " ")
                : replacement
        )

        outputContinuation?.yield(
            TranscriptUpdate(finalized: confirmedText, volatile: volatileText)
        )
    }

    private func inferFinalTranscript() async throws -> String {
        guard let whisperKit else { throw StreamingTranscriberError.notPrepared }

        var options = decodingOptions
        options.clipTimestamps = [lastConfirmedSegmentEnd]
        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        if let language = results.lazy.map(\.language).first(where: { !$0.isEmpty }) {
            detectedLanguage = language
        }

        let tail = StreamingTranscriptText.normalized(
            results.map(\.text).joined(separator: " ")
        )
        return StreamingTranscriptText.join(
            confirmedText,
            tail.isEmpty ? volatileText : tail
        )
    }

    private func validate(_ chunk: AudioChunk) throws {
        guard chunk.sampleRate == Self.requiredSampleRate else {
            throw StreamingTranscriberError.unsupportedSampleRate(
                expected: Self.requiredSampleRate,
                actual: chunk.sampleRate
            )
        }

        if let lastSequence, chunk.sequence != lastSequence + 1 {
            throw StreamingTranscriberError.inferenceFailed(
                "Audio chunk sequence jumped from \(lastSequence) to \(chunk.sequence); "
                    + "the bounded recorder stream overflowed"
            )
        }
        lastSequence = chunk.sequence
    }

    private func failSession(_ error: StreamingTranscriberError, id: UUID) {
        guard sessionID == id else { return }
        sessionFailure = error
        outputContinuation?.finish()
    }

    private func closeSession(id: UUID) {
        guard sessionID == id else { return }
        outputContinuation?.finish()
        outputContinuation = nil
        worker = nil
        sessionID = nil
        resetSessionBuffers()
    }

    private func cancel(sessionID id: UUID) async {
        guard sessionID == id else { return }
        let activeWorker = worker
        let continuation = outputContinuation

        sessionID = nil
        worker = nil
        outputContinuation = nil
        resetSessionBuffers()

        activeWorker?.cancel()
        continuation?.finish()
    }

    private func resetSessionBuffers() {
        sessionFailure = nil
        lastSequence = nil
        samples.removeAll(keepingCapacity: true)
        lastInferenceSampleCount = 0
        confirmedText = ""
        volatileText = ""
        lastConfirmedSegmentEnd = 0
        detectedLanguage = nil
    }
}
