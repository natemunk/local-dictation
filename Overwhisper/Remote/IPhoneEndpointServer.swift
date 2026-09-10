import Foundation
import Hummingbird
import HummingbirdWebSocket
import HTTPTypes
import Logging
import os
import ServiceLifecycle

actor IPhoneEndpointServer {
    typealias HealthProvider = @Sendable () async -> IPhoneEndpointHealthResponse
    typealias TranscriptionHandler = @Sendable (
        IPhoneTranscriptionRequest
    ) async throws -> IPhoneTranscriptionResponse
    typealias StreamingHandler = @Sendable (
        IPhoneAudioStreamRequest
    ) async throws -> IPhoneAudioStreamSession
    typealias StateHandler = @Sendable (IPhoneEndpointLifecycleState) async -> Void
    typealias DiagnosticHandler = @Sendable (IPhoneEndpointDiagnosticEvent) -> Void
    /// Returns the live unified-history provider, or `nil` when unified history
    /// is off. The closure is consulted per request so toggling the setting
    /// never requires restarting the listener.
    typealias HistoryProvider = @Sendable () async -> (any HistorySyncProviding)?

    static let host = "127.0.0.1"
    static let port = 43_129

    private var serverTask: Task<IPhoneEndpointLifecycleState, Never>?
    private var serviceGroup: ServiceGroup?
    private var generation: UInt64 = 0
    private let bindHost: String
    private let bindPort: Int

    init(
        host: String = IPhoneEndpointServer.host,
        port: Int = IPhoneEndpointServer.port
    ) {
        bindHost = host
        bindPort = port
    }

    func start(
        health: @escaping HealthProvider,
        transcribe: @escaping TranscriptionHandler,
        stream: @escaping StreamingHandler = { _ in
            throw IPhoneEndpointFailure(.engineUnavailable)
        },
        history: @escaping HistoryProvider = { nil },
        stateChanged: @escaping StateHandler
    ) async {
        guard serverTask == nil else { return }
        generation &+= 1
        let activeGeneration = generation
        let host = bindHost
        let port = bindPort
        await stateChanged(.starting)
        IPhoneEndpointDiagnostics.emit(.make(
            event: "listener_starting",
            route: "listener",
            outcome: "started"
        ))

        var logger = Logger(label: "com.natemunk.LocalDictation.iPhoneEndpoint")
        logger.logLevel = .warning
        let router = Self.makeRouter(health: health, transcribe: transcribe, history: history)
        let webSocketRouter = Self.makeWebSocketRouter(stream: stream)
        let application = Application(
            router: router,
            server: .http1WebSocketUpgrade(
                webSocketRouter: webSocketRouter,
                configuration: .init(ws: .init(maxFrameSize: IPhoneStreamWAVWriter.maximumFrameBytes))
            ),
            configuration: .init(
                address: .hostname(host, port: port),
                serverName: "LocalDictation"
            ),
            onServerRunning: { _ in
                IPhoneEndpointDiagnostics.emit(.make(
                    event: "listener_ready",
                    route: "listener",
                    status: 200,
                    outcome: "succeeded"
                ))
                await stateChanged(.ready)
            },
            logger: logger
        )
        let group = ServiceGroup(services: [application], logger: logger)
        serviceGroup = group

        let task = Task.detached(priority: .utility) { () -> IPhoneEndpointLifecycleState in
            do {
                try await group.run()
                return .disabled
            } catch is CancellationError {
                // Expected when the endpoint is disabled or the app exits.
                return .disabled
            } catch {
                IPhoneEndpointDiagnostics.emit(.make(
                    event: "listener_failed",
                    route: "listener",
                    status: 500,
                    outcome: "failed",
                    failure: .transcriptionFailed
                ))
                return .failed
            }
        }
        serverTask = task

        Task { [weak self] in
            let terminalState = await task.value
            await self?.serverDidStop(
                generation: activeGeneration,
                terminalState: terminalState,
                stateChanged: stateChanged
            )
        }
    }

    static func makeRouter(
        health: @escaping HealthProvider,
        transcribe: @escaping TranscriptionHandler,
        history: @escaping HistoryProvider = { nil },
        diagnostic: @escaping DiagnosticHandler = { event in
            IPhoneEndpointDiagnostics.emit(event)
        }
    ) -> Router<BasicRequestContext> {
        let router = Router()
        router.get("/healthz") { request, _ -> Response in
            let startedAt = Date()
            let snapshot = await health()
            diagnostic(.make(
                event: "health_completed",
                requestID: Self.requestID(from: request),
                route: "health",
                status: 200,
                outcome: snapshot.ready && !snapshot.busy ? "succeeded" : "degraded",
                latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt)
            ))
            return Self.jsonResponse(snapshot, status: .ok)
        }
        router.post("/v1/transcriptions") { request, _ -> Response in
            let startedAt = Date()
            let headerRequestID = Self.requestID(from: request)
            var parsedRequest: IPhoneTranscriptionRequest?
            do {
                let parsed = try await Self.parse(request)
                parsedRequest = parsed
                diagnostic(.make(
                    event: "transcription_started",
                    request: parsed,
                    route: "transcription",
                    outcome: "started"
                ))
                let response = try await transcribe(parsed)
                diagnostic(.make(
                    event: "transcription_completed",
                    request: parsed,
                    route: response.route.rawValue,
                    status: 200,
                    outcome: "succeeded",
                    cleanup: response.cleanup,
                    historyState: response.historyState,
                    latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt)
                ))
                return Self.jsonResponse(response, status: .ok)
            } catch let failure as IPhoneEndpointFailure {
                diagnostic(.make(
                    event: "transcription_failed",
                    request: parsedRequest,
                    requestID: headerRequestID,
                    route: "transcription",
                    status: Self.status(for: failure.kind).code,
                    outcome: "failed",
                    failure: failure.kind,
                    latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt)
                ))
                return Self.errorResponse(failure.kind)
            } catch is CancellationError {
                diagnostic(.make(
                    event: "transcription_failed",
                    request: parsedRequest,
                    requestID: headerRequestID,
                    route: "transcription",
                    status: Self.status(for: .remotePreempted).code,
                    outcome: "failed",
                    failure: .remotePreempted,
                    latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt)
                ))
                return Self.errorResponse(.remotePreempted)
            } catch {
                diagnostic(.make(
                    event: "transcription_failed",
                    request: parsedRequest,
                    requestID: headerRequestID,
                    route: "transcription",
                    status: Self.status(for: .transcriptionFailed).code,
                    outcome: "failed",
                    failure: .transcriptionFailed,
                    latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt)
                ))
                return Self.errorResponse(.transcriptionFailed)
            }
        }
        router.get("/v1/history/manifest") { _, _ -> Response in
            do {
                let provider = try await Self.requireHistory(history)
                return Self.historyJSONResponse(try await provider.manifest(), status: .ok)
            } catch {
                return Self.historyErrorResponse(for: error)
            }
        }
        router.get("/v1/history") { request, _ -> Response in
            do {
                let provider = try await Self.requireHistory(history)
                let query = try Self.parseHistoryQuery(request)
                let page = try await provider.page(
                    revision: query.revision,
                    cursor: query.cursor,
                    limit: query.limit
                )
                return Self.historyJSONResponse(page, status: .ok)
            } catch {
                return Self.historyErrorResponse(for: error)
            }
        }
        router.post("/v1/history/operations") { request, _ -> Response in
            do {
                let provider = try await Self.requireHistory(history)
                let batch = try await Self.parseHistoryBatch(request)
                return Self.historyJSONResponse(try await provider.apply(batch), status: .ok)
            } catch {
                return Self.historyErrorResponse(for: error)
            }
        }
        return router
    }

    static func makeWebSocketRouter(
        stream: @escaping StreamingHandler,
        diagnostic: @escaping DiagnosticHandler = { event in
            IPhoneEndpointDiagnostics.emit(event)
        }
    ) -> Router<BasicWebSocketRequestContext> {
        let router = Router(context: BasicWebSocketRequestContext.self)
        router.ws("/v1/stream", shouldUpgrade: { request, _ in
            do {
                _ = try Self.parseStreamRequest(request)
                let protocols = request.headers[Self.webSocketProtocolHeader]?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? []
                guard protocols.contains(Self.webSocketProtocol) else {
                    return .dontUpgrade
                }
                return .upgrade([
                    Self.webSocketProtocolHeader: Self.webSocketProtocol
                ])
            } catch {
                return .dontUpgrade
            }
        }, onUpgrade: { inbound, outbound, context in
            let startedAt = Date()
            let request = try Self.parseStreamRequest(context.request)
            let session = try await stream(request)
            diagnostic(.make(
                event: "stream_started",
                streamRequest: request,
                route: "stream",
                outcome: "started"
            ))
            let sender = Task<Void, Error> {
                let encoder = JSONEncoder()
                for await event in session.events {
                    try Task.checkCancellation()
                    let data = try encoder.encode(event)
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw IPhoneEndpointFailure(.transcriptionFailed)
                    }
                    try await outbound.write(.text(text))
                    switch event {
                    case .final(let response):
                        diagnostic(.make(
                            event: "stream_completed",
                            streamRequest: request,
                            route: response.route.rawValue,
                            status: 200,
                            outcome: "succeeded",
                            cleanup: response.cleanup,
                            historyState: response.historyState,
                            latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt)
                        ))
                    case .error(_, let kind):
                        diagnostic(.make(
                            event: "stream_failed",
                            streamRequest: request,
                            route: "stream",
                            status: Self.status(for: kind).code,
                            outcome: "failed",
                            failure: kind,
                            latencyMilliseconds: Self.elapsedMilliseconds(since: startedAt)
                        ))
                    case .ready, .partial, .audioReceived, .previewUnavailable:
                        break
                    }
                }
            }

            do {
                for try await message in inbound.messages(
                    maxSize: IPhoneStreamWAVWriter.maximumFrameBytes
                ) {
                    switch message {
                    case .binary(let buffer):
                        try await session.receiveAudio(Data(buffer.readableBytesView))
                    case .text(let text):
                        switch try IPhoneStreamControl.decode(text) {
                        case .cancel:
                            await session.cancel()
                            _ = try? await sender.value
                            return
                        case .finish(let durationSeconds):
                            try await session.finish(durationSeconds)
                            try await sender.value
                            return
                        }
                    }
                }
                await session.cancel()
                sender.cancel()
                _ = try? await sender.value
            } catch {
                await session.cancel()
                _ = try? await sender.value
                throw error
            }
        })
        return router
    }

    func stop(stateChanged: @escaping StateHandler) async {
        generation &+= 1
        let task = serverTask
        let group = serviceGroup
        serverTask = nil
        serviceGroup = nil
        await group?.triggerGracefulShutdown()
        if let task { _ = await task.value }
        IPhoneEndpointDiagnostics.emit(.make(
            event: "listener_stopped",
            route: "listener",
            outcome: "succeeded"
        ))
        await stateChanged(.disabled)
    }

    private func serverDidStop(
        generation completedGeneration: UInt64,
        terminalState: IPhoneEndpointLifecycleState,
        stateChanged: @escaping StateHandler
    ) async {
        guard completedGeneration == generation else { return }
        serverTask = nil
        serviceGroup = nil
        await stateChanged(terminalState)
    }

    private static func parse(_ request: Request) async throws -> IPhoneTranscriptionRequest {
        let contentType = request.headers[.contentType]?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let contentType, supportedMediaTypes.contains(contentType) else {
            throw IPhoneEndpointFailure(.unsupportedMedia)
        }

        if let contentLength = request.headers[.contentLength].flatMap(Int.init),
           contentLength > IPhoneTranscriptionRequest.maximumBodyBytes {
            throw IPhoneEndpointFailure(.payloadTooLarge)
        }

        let client = try Self.parseClient(request)

        guard let requestIDHeader = request.headers[Self.requestIDHeader],
              let requestID = UUID(uuidString: requestIDHeader),
              let modeHeader = request.headers[Self.modeHeader]?.lowercased(),
              let mode = CleanupMode(rawValue: modeHeader),
              let fallbackHeader = request.headers[Self.fallbackHeader]?.lowercased(),
              ["true", "false"].contains(fallbackHeader),
              let durationHeader = request.headers[Self.durationHeader],
              let duration = TimeInterval(durationHeader),
              duration.isFinite,
              duration > 0
        else {
            throw IPhoneEndpointFailure(.invalidRequest)
        }
        guard duration <= IPhoneTranscriptionRequest.maximumDurationSeconds else {
            throw IPhoneEndpointFailure(.durationTooLong)
        }

        let buffer: ByteBuffer
        do {
            buffer = try await request.body.collect(
                upTo: IPhoneTranscriptionRequest.maximumBodyBytes
            )
        } catch {
            throw IPhoneEndpointFailure(.payloadTooLarge)
        }
        guard let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes),
              !bytes.isEmpty
        else { throw IPhoneEndpointFailure(.invalidRequest) }

        return IPhoneTranscriptionRequest(
            requestID: requestID,
            mode: mode,
            allowsCloudFallback: fallbackHeader == "true",
            claimedDurationSeconds: duration,
            mediaType: contentType,
            audio: Data(bytes),
            client: client
        )
    }

    private static func parseStreamRequest(_ request: Request) throws -> IPhoneAudioStreamRequest {
        guard request.headers[Self.transportHeader]?.lowercased() == "stream-v1",
              let requestIDHeader = request.headers[Self.requestIDHeader],
              let requestID = UUID(uuidString: requestIDHeader),
              let modeHeader = request.headers[Self.modeHeader]?.lowercased(),
              let mode = CleanupMode(rawValue: modeHeader),
              let fallbackHeader = request.headers[Self.fallbackHeader]?.lowercased(),
              ["true", "false"].contains(fallbackHeader),
              try Self.parseClient(request) == .pwa
        else { throw IPhoneEndpointFailure(.invalidRequest) }

        return IPhoneAudioStreamRequest(
            requestID: requestID,
            mode: mode,
            allowsCloudFallback: fallbackHeader == "true",
            client: .pwa
        )
    }

    private static func requestID(from request: Request) -> UUID? {
        guard let value = request.headers[requestIDHeader] else { return nil }
        return UUID(uuidString: value)
    }

    private static func elapsedMilliseconds(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1_000).rounded()))
    }

    /// `X-Dictation-Client` is optional and defaults to the Shortcut. Any other
    /// value is a client bug and must not be silently coerced.
    private static func parseClient(_ request: Request) throws -> IPhoneDictationClient {
        guard let header = request.headers[Self.clientHeader] else { return .shortcut }
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let client = IPhoneDictationClient(rawValue: value) else {
            throw IPhoneEndpointFailure(.invalidRequest)
        }
        return client
    }

    // MARK: - Unified history

    private static func requireHistory(
        _ history: @escaping HistoryProvider
    ) async throws -> any HistorySyncProviding {
        guard let provider = await history() else { throw HistorySyncError.historyDisabled }
        return provider
    }

    private static func parseHistoryQuery(
        _ request: Request
    ) throws -> (revision: Int64, cursor: String?, limit: Int) {
        let parameters = request.uri.queryParameters
        guard let revisionValue = parameters["revision"],
              let revision = Int64(revisionValue),
              revision >= 0
        else { throw HistorySyncError.invalidRequest }

        var cursor: String?
        if let cursorValue = parameters["cursor"], !cursorValue.isEmpty {
            guard cursorValue.count <= maximumHistoryCursorCharacters else {
                throw HistorySyncError.invalidRequest
            }
            cursor = String(cursorValue)
        }

        var limit = HistorySyncManifest.maximumPageSize
        if let limitValue = parameters["limit"] {
            guard let parsed = Int(limitValue),
                  (1...HistorySyncManifest.maximumPageSize).contains(parsed)
            else { throw HistorySyncError.invalidRequest }
            limit = parsed
        }

        return (revision, cursor, limit)
    }

    private static func parseHistoryBatch(
        _ request: Request
    ) async throws -> HistorySyncOperationBatch {
        let contentType = request.headers[.contentType]?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard contentType == "application/json" else { throw HistorySyncError.invalidRequest }

        if let contentLength = request.headers[.contentLength].flatMap(Int.init),
           contentLength > maximumHistoryBodyBytes {
            throw HistorySyncError.payloadTooLarge
        }

        let buffer: ByteBuffer
        do {
            buffer = try await request.body.collect(upTo: maximumHistoryBodyBytes)
        } catch {
            throw HistorySyncError.payloadTooLarge
        }
        guard let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes),
              !bytes.isEmpty
        else { throw HistorySyncError.invalidRequest }

        let batch: HistorySyncOperationBatch
        do {
            batch = try HistorySyncJSON.makeDecoder().decode(
                HistorySyncOperationBatch.self,
                from: Data(bytes)
            )
        } catch {
            throw HistorySyncError.invalidRequest
        }
        guard (1...HistorySyncManifest.maximumOperationsPerRequest)
            .contains(batch.operations.count)
        else { throw HistorySyncError.invalidRequest }
        return batch
    }

    private static func historyJSONResponse<Value: Encodable>(
        _ value: Value,
        status: HTTPResponse.Status
    ) -> Response {
        let data = (try? HistorySyncJSON.makeEncoder().encode(value))
            ?? Data(#"{"error":"history_failed"}"#.utf8)
        return jsonResponse(data: data, status: status)
    }

    /// Error bodies never carry error descriptions; they would leak store
    /// paths, SQL, and in the worst case transcript fragments.
    private static func historyErrorResponse(for error: Error) -> Response {
        guard let syncError = error as? HistorySyncError else {
            return historyJSONResponse(
                HistoryErrorBody(error: "history_failed"),
                status: .internalServerError
            )
        }
        switch syncError {
        case .historyDisabled:
            return historyJSONResponse(
                HistoryErrorBody(error: "history_disabled"),
                status: .forbidden
            )
        case .invalidRequest:
            return historyJSONResponse(
                HistoryErrorBody(error: "invalid_request"),
                status: .badRequest
            )
        case .payloadTooLarge:
            return historyJSONResponse(
                HistoryErrorBody(error: "payload_too_large"),
                status: .contentTooLarge
            )
        case let .historyChanged(currentRevision):
            return historyJSONResponse(
                HistoryChangedBody(revision: currentRevision),
                status: .conflict
            )
        }
    }

    private struct HistoryErrorBody: Encodable {
        let error: String
    }

    private struct HistoryChangedBody: Encodable {
        let error = "history_changed"
        let revision: Int64
    }

    private static func jsonResponse<Value: Encodable>(
        _ value: Value,
        status: HTTPResponse.Status
    ) -> Response {
        let data = (try? JSONEncoder().encode(value)) ?? Data(#"{"error":"transcription_failed"}"#.utf8)
        return jsonResponse(data: data, status: status)
    }

    private static func jsonResponse(data: Data, status: HTTPResponse.Status) -> Response {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return Response(
            status: status,
            headers: [
                .contentType: "application/json; charset=utf-8",
                .cacheControl: "no-store",
            ],
            body: .init(byteBuffer: buffer)
        )
    }

    private static func errorResponse(_ kind: IPhoneEndpointErrorKind) -> Response {
        jsonResponse(IPhoneEndpointErrorResponse(error: kind), status: status(for: kind))
    }

    private static func status(for kind: IPhoneEndpointErrorKind) -> HTTPResponse.Status {
        switch kind {
        case .invalidRequest: .badRequest
        case .unsupportedMedia: .unsupportedMediaType
        case .payloadTooLarge: .contentTooLarge
        case .durationTooLong, .emptyTranscript: .unprocessableContent
        case .desktopBusy, .remoteBusy: .conflict
        case .engineUnavailable, .remotePreempted: .serviceUnavailable
        case .transcriptionTimedOut: .gatewayTimeout
        case .transcriptionFailed: .internalServerError
        }
    }

    private static let requestIDHeader = HTTPField.Name("X-Request-ID")!
    private static let modeHeader = HTTPField.Name("X-Dictation-Mode")!
    private static let fallbackHeader = HTTPField.Name("X-Allow-Cloud-Fallback")!
    private static let durationHeader = HTTPField.Name("X-Audio-Duration-Seconds")!
    private static let clientHeader = HTTPField.Name("X-Dictation-Client")!
    private static let transportHeader = HTTPField.Name("X-Dictation-Transport")!
    private static let webSocketProtocolHeader = HTTPField.Name("Sec-WebSocket-Protocol")!
    private static let webSocketProtocol = "local-dictation.v1"
    private static let maximumHistoryBodyBytes = 2 * 1_024 * 1_024
    private static let maximumHistoryCursorCharacters = 64
    private static let supportedMediaTypes: Set<String> = [
        "audio/m4a",
        "audio/mp4",
        "audio/x-m4a",
        "audio/wav",
        "audio/x-wav",
        "audio/wave",
    ]
}
