import Foundation

actor IPhoneRemoteStreamingSession {
    typealias Finalizer = @Sendable (
        IPhoneStreamedAudio,
        TimeInterval
    ) async throws -> IPhoneLocalProcessingResult
    typealias Completion = @Sendable (
        Result<IPhoneLocalProcessingResult, IPhoneEndpointFailure>
    ) async -> Void

    private enum State {
        case active
        case finalizing
        case finished
    }

    private let request: IPhoneAudioStreamRequest
    private let writer: IPhoneStreamWAVWriter
    private let source = BoundedAudioChunkStream(bufferingLimit: 256)
    private let transcriber: any StreamingTranscriber
    private let finalizer: Finalizer
    private let completion: Completion
    private let continuation: AsyncStream<IPhoneStreamServerMessage>.Continuation

    private var state = State.active
    private var previewTask: Task<Void, Never>?
    private var finalizationTask: Task<IPhoneLocalProcessingResult, Error>?
    private var receivedFrames = 0
    private var partialCount = 0
    private var previewUnavailable = false

    let events: AsyncStream<IPhoneStreamServerMessage>

    init(
        request: IPhoneAudioStreamRequest,
        writer: IPhoneStreamWAVWriter,
        transcriber: any StreamingTranscriber,
        finalizer: @escaping Finalizer,
        completion: @escaping Completion
    ) {
        self.request = request
        self.writer = writer
        self.transcriber = transcriber
        self.finalizer = finalizer
        self.completion = completion
        let pair = AsyncStream<IPhoneStreamServerMessage>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    func start() -> IPhoneAudioStreamSession {
        if state == .active {
            continuation.yield(.ready(requestID: request.requestID))
            startPreview()
        }
        let events = events
        return IPhoneAudioStreamSession(
            events: events,
            receiveAudio: { data in
                try await self.receiveAudio(data)
            },
            finish: { duration in
                try await self.finish(claimedDuration: duration)
            },
            cancel: {
                await self.cancel()
            }
        )
    }

    private func startPreview() {
        let transcriber = transcriber
        let samples = source.stream
        previewTask = Task { [weak self] in
            do {
                let updates = try await transcriber.start(samples: samples)
                for await update in updates {
                    try Task.checkCancellation()
                    await self?.publish(update)
                }
                await self?.markPreviewUnavailable()
            } catch {
                // Live text is optional. The complete WAV and authoritative
                // final engine remain available even when preview cannot load.
                await self?.markPreviewUnavailable()
            }
        }
    }

    private func markPreviewUnavailable() {
        guard state == .active, !previewUnavailable else { return }
        previewUnavailable = true
        continuation.yield(.previewUnavailable(requestID: request.requestID))
    }

    private func publish(_ update: TranscriptUpdate) {
        guard state == .active else { return }
        let text = TranscriptBufferText.join(update.finalized, update.volatile)
        guard !text.isEmpty else { return }
        partialCount += 1
        continuation.yield(.partial(requestID: request.requestID, text: text))
    }

    private func receiveAudio(_ data: Data) async throws {
        guard state == .active else { throw IPhoneEndpointFailure(.invalidRequest) }
        do {
            let samples = try await writer.append(data)
            guard state == .active else { throw IPhoneEndpointFailure(.remotePreempted) }
            _ = source.yield(samples: samples)
            receivedFrames += 1
            // Receipt is acknowledged after the WAV write, never merely after
            // an upgrade. Throttle metadata to the first frame and every 25th.
            if receivedFrames == 1 || receivedFrames.isMultiple(of: 25) {
                continuation.yield(.audioReceived(
                    requestID: request.requestID,
                    frames: receivedFrames,
                    partials: partialCount
                ))
            }
        } catch IPhoneStreamWAVError.tooLong {
            await fail(.durationTooLong)
            throw IPhoneEndpointFailure(.durationTooLong)
        } catch {
            await fail(.invalidRequest)
            throw IPhoneEndpointFailure(.invalidRequest)
        }
    }

    private func finish(claimedDuration: TimeInterval) async throws {
        guard state == .active else { throw IPhoneEndpointFailure(.invalidRequest) }
        state = .finalizing
        source.finish()
        previewTask?.cancel()
        await transcriber.cancel()
        guard state == .finalizing, !Task.isCancelled else {
            throw IPhoneEndpointFailure(.remotePreempted)
        }
        await previewTask?.value
        previewTask = nil
        guard state == .finalizing, !Task.isCancelled else {
            throw IPhoneEndpointFailure(.remotePreempted)
        }

        let audio: IPhoneStreamedAudio
        do {
            audio = try await writer.finish()
        } catch {
            await fail(.invalidRequest)
            throw IPhoneEndpointFailure(.invalidRequest)
        }
        guard state == .finalizing, !Task.isCancelled else {
            audio.removeFile()
            throw IPhoneEndpointFailure(.remotePreempted)
        }

        // The sample-derived duration is authoritative. A wildly inconsistent
        // browser claim is rejected instead of weakening the ten-minute cap.
        guard abs(audio.durationSeconds - claimedDuration) <= max(2, audio.durationSeconds * 0.15) else {
            audio.removeFile()
            await fail(.invalidRequest)
            throw IPhoneEndpointFailure(.invalidRequest)
        }

        let finalizer = finalizer
        let task = Task.detached(priority: .utility) {
            try await finalizer(audio, audio.durationSeconds)
        }
        finalizationTask = task
        do {
            let result = try await task.value
            audio.removeFile()
            guard state == .finalizing else { throw CancellationError() }
            continuation.yield(.final(result.response))
            continuation.finish()
            state = .finished
            finalizationTask = nil
            await completion(.success(result))
        } catch is CancellationError {
            audio.removeFile()
            await fail(.remotePreempted)
            throw IPhoneEndpointFailure(.remotePreempted)
        } catch let failure as IPhoneEndpointFailure {
            audio.removeFile()
            await fail(failure.kind)
            throw failure
        } catch {
            audio.removeFile()
            await fail(.transcriptionFailed)
            throw IPhoneEndpointFailure(.transcriptionFailed)
        }
    }

    func cancel() async {
        await fail(.remotePreempted, emitEvent: false)
    }

    private func fail(
        _ kind: IPhoneEndpointErrorKind,
        emitEvent: Bool = true
    ) async {
        guard state != .finished else { return }
        state = .finished
        source.cancel()
        let preview = previewTask
        let finalizer = finalizationTask
        preview?.cancel()
        finalizer?.cancel()
        // Mark terminal before suspension so finish() cannot launch new work.
        // Keep ownership until inference actually exits: cancel() is a request,
        // not proof that a Core ML operation has stopped using the shared engine.
        await transcriber.cancel()
        await preview?.value
        _ = try? await finalizer?.value
        previewTask = nil
        finalizationTask = nil
        await writer.cancel()
        if emitEvent {
            continuation.yield(.error(requestID: request.requestID, kind: kind))
        }
        continuation.finish()
        await completion(.failure(IPhoneEndpointFailure(kind)))
    }
}

private enum TranscriptBufferText {
    static func join(_ finalized: String, _ volatile: String) -> String {
        let left = finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        return "\(left) \(right)"
    }
}
