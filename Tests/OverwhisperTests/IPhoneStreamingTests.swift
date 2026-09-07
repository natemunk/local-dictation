import Foundation
import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import HummingbirdWSTesting
import HTTPTypes
import Testing
@testable import LocalDictation

@Suite("iPhone live transcription")
struct IPhoneStreamingTests {
    @Test("control messages are bounded and unambiguous")
    func controlMessages() throws {
        #expect(try IPhoneStreamControl.decode(#"{"type":"cancel"}"#) == .cancel)
        #expect(
            try IPhoneStreamControl.decode(#"{"type":"finish","duration_seconds":2.5}"#)
                == .finish(durationSeconds: 2.5)
        )
        #expect(throws: IPhoneEndpointFailure.self) {
            try IPhoneStreamControl.decode(#"{"type":"finish","duration_seconds":0}"#)
        }
        #expect(throws: IPhoneEndpointFailure.self) {
            try IPhoneStreamControl.decode(#"{"type":"unknown"}"#)
        }
    }

    @Test("PCM frames become an exact 16 kHz mono WAV")
    func wavWriter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "local-dictation-stream-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try IPhoneStreamWAVWriter(
            requestID: UUID(),
            temporaryDirectory: directory
        )
        let samples = [Int16.min, -1, 0, 1, Int16.max]
        let frame = Self.pcmData(samples)
        let floats = try await writer.append(frame)
        #expect(floats.count == samples.count)
        #expect(floats[0] == -1)
        #expect(floats[2] == 0)

        let audio = try await writer.finish()
        #expect(abs(audio.durationSeconds - (5.0 / 16_000.0)) < 0.000_001)
        let bytes = try Data(contentsOf: audio.wavURL)
        #expect(bytes.count == 44 + frame.count)
        #expect(String(data: bytes[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: bytes[8..<12], encoding: .ascii) == "WAVE")
        #expect(Self.uint32(bytes, offset: 24) == 16_000)
        #expect(Self.uint16(bytes, offset: 22) == 1)
        #expect(Self.uint16(bytes, offset: 34) == 16)
        #expect(Self.uint32(bytes, offset: 40) == UInt32(frame.count))
        #expect(bytes[44...] == frame[...])

        audio.removeFile()
        #expect(!FileManager.default.fileExists(atPath: audio.wavURL.path))
    }

    @Test("streaming session emits live text then authoritative final text and deletes audio")
    func streamingSessionLifecycle() async throws {
        let requestID = UUID()
        let preview = PreviewStub()
        let completion = CompletionProbe()
        let captured = AudioProbe()
        let writer = try IPhoneStreamWAVWriter(requestID: requestID)
        let request = IPhoneAudioStreamRequest(
            requestID: requestID,
            mode: .clean,
            allowsCloudFallback: true,
            client: .pwa
        )
        let response = IPhoneTranscriptionResponse(
            requestID: requestID,
            text: "Authoritative final.",
            route: .macLocal,
            cleanup: .deterministic,
            latencyMilliseconds: 80,
            fallbackReason: nil,
            historyState: .savedOnMac
        )
        let session = IPhoneRemoteStreamingSession(
            request: request,
            writer: writer,
            transcriber: preview,
            finalizer: { audio, duration in
                await captured.save(url: audio.wavURL, duration: duration)
                return IPhoneLocalProcessingResult(
                    response: response,
                    rawWordCount: 2,
                    deliveredWordCount: 2,
                    audioDurationSeconds: duration,
                    asrLatencySeconds: 0.05,
                    cleanupLatencySeconds: 0.01,
                    recognizedCommandCount: 0,
                    cleanupOutcome: "deterministic"
                )
            },
            completion: { result in await completion.save(result) }
        )
        let handle = await session.start()
        var iterator = handle.events.makeAsyncIterator()
        #expect(await iterator.next() == .ready(requestID: requestID))

        let samples = [Int16](repeating: 1_000, count: 3_200)
        try await handle.receiveAudio(Self.pcmData(samples))
        #expect(
            await iterator.next()
                == .partial(requestID: requestID, text: "Live words")
        )
        try await handle.finish(0.2)

        #expect(await iterator.next() == .final(response))
        #expect(await iterator.next() == nil)
        let saved = await captured.value
        #expect(saved?.duration == 0.2)
        #expect(saved.map { !FileManager.default.fileExists(atPath: $0.url.path) } == true)
        #expect(await completion.succeeded)
    }

    @Test("WebSocket route validates metadata and carries binary audio to final response")
    func webSocketRoute() async throws {
        let requestID = UUID()
        let probe = SocketProbe()
        let router = IPhoneEndpointServer.makeWebSocketRouter { request in
            #expect(request.requestID == requestID)
            #expect(request.mode == .literal)
            #expect(request.client == .pwa)
            let pair = AsyncStream<IPhoneStreamServerMessage>.makeStream()
            pair.continuation.yield(.ready(requestID: request.requestID))
            return IPhoneAudioStreamSession(
                events: pair.stream,
                receiveAudio: { data in await probe.receive(data) },
                finish: { duration in
                    await probe.finish(duration)
                    pair.continuation.yield(.final(IPhoneTranscriptionResponse(
                        requestID: request.requestID,
                        text: "Socket final.",
                        route: .macLocal,
                        cleanup: .none,
                        latencyMilliseconds: 12,
                        fallbackReason: nil
                    )))
                    pair.continuation.finish()
                },
                cancel: { pair.continuation.finish() }
            )
        }
        let app = Application(
            router: Router(),
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname("127.0.0.1", port: 0))
        )
        let headers: HTTPFields = [
            HTTPField.Name("Sec-WebSocket-Protocol")!: "local-dictation.v1",
            HTTPField.Name("X-Request-ID")!: requestID.uuidString,
            HTTPField.Name("X-Dictation-Mode")!: "literal",
            HTTPField.Name("X-Dictation-Client")!: "pwa",
            HTTPField.Name("X-Allow-Cloud-Fallback")!: "true",
            HTTPField.Name("X-Dictation-Transport")!: "stream-v1",
        ]

        _ = try await app.test(.live) { client in
            try await client.ws(
                "/v1/stream",
                configuration: .init(additionalHeaders: headers)
            ) { inbound, outbound, _ in
                var iterator = inbound.messages(maxSize: 64 * 1_024).makeAsyncIterator()
                let ready = try #require(await iterator.next())
                guard case .text(let readyText) = ready else {
                    Issue.record("Expected ready text")
                    return
                }
                let readyObject = try Self.jsonObject(readyText)
                #expect(readyObject["type"] as? String == "ready")

                try await outbound.write(.binary(ByteBuffer(bytes: [1, 0, 2, 0])))
                try await outbound.write(.text(#"{"type":"finish","duration_seconds":1}"#))

                let final = try #require(await iterator.next())
                guard case .text(let finalText) = final else {
                    Issue.record("Expected final text")
                    return
                }
                let finalObject = try Self.jsonObject(finalText)
                #expect(finalObject["type"] as? String == "final")
                #expect(finalObject["text"] as? String == "Socket final.")
            }
        }

        #expect(await probe.bytes == Data([1, 0, 2, 0]))
        #expect(await probe.duration == 1)
    }

    private static func pcmData(_ samples: [Int16]) -> Data {
        let little = samples.map(\.littleEndian)
        return little.withUnsafeBytes { Data($0) }
    }

    private static func uint16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func jsonObject(_ text: String) throws -> [String: Any] {
        let data = try #require(text.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor PreviewStub: StreamingTranscriber {
    private var worker: Task<Void, Never>?
    private var continuation: AsyncStream<TranscriptUpdate>.Continuation?

    func prepare() async throws {}

    func start(samples: AsyncStream<AudioChunk>) async throws -> AsyncStream<TranscriptUpdate> {
        let pair = AsyncStream<TranscriptUpdate>.makeStream()
        continuation = pair.continuation
        worker = Task {
            for await _ in samples {
                pair.continuation.yield(TranscriptUpdate(finalized: "", volatile: "Live words"))
            }
        }
        return pair.stream
    }

    func finish() async throws -> FinalTranscript {
        FinalTranscript(text: "Live words", language: "en")
    }

    func cancel() async {
        worker?.cancel()
        continuation?.finish()
        worker = nil
        continuation = nil
    }
}

private actor CompletionProbe {
    private(set) var succeeded = false
    func save(_ result: Result<IPhoneLocalProcessingResult, IPhoneEndpointFailure>) {
        if case .success = result { succeeded = true }
    }
}

private actor AudioProbe {
    private(set) var value: (url: URL, duration: TimeInterval)?
    func save(url: URL, duration: TimeInterval) { value = (url, duration) }
}

private actor SocketProbe {
    private(set) var bytes = Data()
    private(set) var duration: TimeInterval?
    func receive(_ data: Data) { bytes.append(data) }
    func finish(_ duration: TimeInterval) { self.duration = duration }
}
