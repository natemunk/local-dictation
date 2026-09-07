import AVFoundation
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Testing
@testable import LocalDictation

@Suite("iPhone transcription endpoint")
struct IPhoneEndpointTests {
    @Test("HTTP routes validate requests and always disable caching")
    func httpContract() async throws {
        let requestID = UUID()
        let router = IPhoneEndpointServer.makeRouter(
            health: {
                IPhoneEndpointHealthResponse(
                    ready: true,
                    busy: false,
                    selectedEngine: ASRSelection.parakeetV2.rawValue
                )
            },
            transcribe: { request in
                #expect(request.requestID == requestID)
                #expect(request.mode == .clean)
                #expect(request.allowsCloudFallback)
                #expect(request.audio == Data([1, 2, 3]))
                return IPhoneTranscriptionResponse(
                    requestID: request.requestID,
                    text: "hello",
                    route: .macLocal,
                    cleanup: .deterministic,
                    latencyMilliseconds: 10,
                    fallbackReason: nil
                )
            }
        )
        let application = Application(responder: router.buildResponder())

        try await application.test(.router) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
            }

            let headers: HTTPFields = [
                .contentType: "audio/mp4",
                HTTPField.Name("X-Request-ID")!: requestID.uuidString,
                HTTPField.Name("X-Dictation-Mode")!: "clean",
                HTTPField.Name("X-Allow-Cloud-Fallback")!: "true",
                HTTPField.Name("X-Audio-Duration-Seconds")!: "1.5",
            ]
            try await client.execute(
                uri: "/v1/transcriptions",
                method: .post,
                headers: headers,
                body: ByteBuffer(bytes: [1, 2, 3])
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                let decoded = try JSONDecoder().decode(
                    IPhoneTranscriptionResponse.self,
                    from: Data(response.body.readableBytesView)
                )
                #expect(decoded.requestID == requestID)
                #expect(decoded.text == "hello")
            }

            try await client.execute(
                uri: "/v1/transcriptions",
                method: .post,
                headers: [.contentType: "text/plain"],
                body: ByteBuffer(bytes: [1])
            ) { response in
                #expect(response.status == .unsupportedMediaType)
                #expect(response.headers[.cacheControl] == "no-store")
            }

            var invalidHeaders = headers
            invalidHeaders[HTTPField.Name("X-Request-ID")!] = "not-a-uuid"
            try await client.execute(
                uri: "/v1/transcriptions",
                method: .post,
                headers: invalidHeaders,
                body: ByteBuffer(bytes: [1])
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.headers[.cacheControl] == "no-store")
            }
        }
    }

    @Test("request diagnostics correlate phases without transcript, audio, or raw errors")
    func privacySafeRequestDiagnostics() async throws {
        let requestID = UUID()
        let secretTranscript = "private words must never reach logs"
        let probe = DiagnosticProbe()
        let router = IPhoneEndpointServer.makeRouter(
            health: { Self.readyHealth },
            transcribe: { request in
                IPhoneTranscriptionResponse(
                    requestID: request.requestID,
                    text: secretTranscript,
                    route: .macLocal,
                    cleanup: .deterministic,
                    latencyMilliseconds: 12,
                    fallbackReason: nil,
                    historyState: .savedOnMac
                )
            },
            diagnostic: { probe.record($0) }
        )
        let application = Application(responder: router.buildResponder())

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/v1/transcriptions",
                method: .post,
                headers: Self.transcriptionHeaders(requestID: requestID),
                body: ByteBuffer(bytes: [1, 2, 3])
            ) { response in
                #expect(response.status == .ok)
            }

            var rejectedHeaders = Self.transcriptionHeaders(requestID: requestID)
            rejectedHeaders[.contentType] = "text/plain"
            try await client.execute(
                uri: "/v1/transcriptions",
                method: .post,
                headers: rejectedHeaders,
                body: ByteBuffer(bytes: [1])
            ) { response in
                #expect(response.status == .unsupportedMediaType)
            }
        }

        let events = probe.events
        #expect(events.map(\.event) == [
            "transcription_started",
            "transcription_completed",
            "transcription_failed",
        ])
        #expect(events[0].requestID == requestID.uuidString.lowercased())
        #expect(events[0].client == "shortcut")
        #expect(events[0].mode == "clean")
        #expect(events[0].mediaType == "audio/mp4")
        #expect(events[0].sizeBucket == "tiny")
        #expect(events[0].durationBucket == "short")
        #expect(events[1].route == "mac_local")
        #expect(events[1].cleanup == "deterministic")
        #expect(events[1].historyState == "saved_on_mac")
        #expect(events[2].failureCode == "unsupported_media")

        let serialized = events.map { $0.encodedLine() }.joined(separator: "\n")
        #expect(!serialized.contains(secretTranscript))
        #expect(!serialized.contains("AQID"))
        #expect(!serialized.contains("CF-Access"))
    }

    @Test("the client header selects the source kind and rejects unknown values")
    func clientHeaderContract() async throws {
        let observed = ClientProbe()
        let router = IPhoneEndpointServer.makeRouter(
            health: { Self.readyHealth },
            transcribe: { request in
                observed.record(request.client)
                return IPhoneTranscriptionResponse(
                    requestID: request.requestID,
                    text: "hello",
                    route: .macLocal,
                    cleanup: .deterministic,
                    latencyMilliseconds: 10,
                    fallbackReason: nil,
                    historyState: .savedOnMac
                )
            }
        )
        let application = Application(responder: router.buildResponder())

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/v1/transcriptions",
                method: .post,
                headers: Self.transcriptionHeaders(),
                body: ByteBuffer(bytes: [1, 2, 3])
            ) { response in
                #expect(response.status == .ok)
                let object = try Self.jsonObject(response.body)
                #expect(object["history_state"] as? String == "saved_on_mac")
            }
            #expect(observed.last == .shortcut)

            var pwaHeaders = Self.transcriptionHeaders()
            pwaHeaders[HTTPField.Name("X-Dictation-Client")!] = "pwa"
            try await client.execute(
                uri: "/v1/transcriptions",
                method: .post,
                headers: pwaHeaders,
                body: ByteBuffer(bytes: [1, 2, 3])
            ) { response in
                #expect(response.status == .ok)
            }
            #expect(observed.last == .pwa)

            var shortcutHeaders = Self.transcriptionHeaders()
            shortcutHeaders[HTTPField.Name("X-Dictation-Client")!] = "shortcut"
            try await client.execute(
                uri: "/v1/transcriptions",
                method: .post,
                headers: shortcutHeaders,
                body: ByteBuffer(bytes: [1, 2, 3])
            ) { response in
                #expect(response.status == .ok)
            }
            #expect(observed.last == .shortcut)

            var invalidHeaders = Self.transcriptionHeaders()
            invalidHeaders[HTTPField.Name("X-Dictation-Client")!] = "watch"
            try await client.execute(
                uri: "/v1/transcriptions",
                method: .post,
                headers: invalidHeaders,
                body: ByteBuffer(bytes: [1, 2, 3])
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.headers[.cacheControl] == "no-store")
            }
            #expect(observed.callCount == 3)
        }
    }

    @Test("history routes answer history_disabled while unified history is off")
    func historyDisabledWithoutProvider() async throws {
        let router = IPhoneEndpointServer.makeRouter(
            health: { Self.readyHealth },
            transcribe: { _ in throw IPhoneEndpointFailure(.engineUnavailable) }
        )
        let application = Application(responder: router.buildResponder())

        try await application.test(.router) { client in
            for uri in ["/v1/history/manifest", "/v1/history?revision=0"] {
                try await client.execute(uri: uri, method: .get) { response in
                    #expect(response.status == .forbidden)
                    #expect(response.headers[.cacheControl] == "no-store")
                    let object = try Self.jsonObject(response.body)
                    #expect(object["error"] as? String == "history_disabled")
                }
            }

            try await client.execute(
                uri: "/v1/history/operations",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"operations":[]}"#)
            ) { response in
                #expect(response.status == .forbidden)
                let object = try Self.jsonObject(response.body)
                #expect(object["error"] as? String == "history_disabled")
            }
        }
    }

    @Test("manifest and snapshot pages follow the unified history contract")
    func historyManifestAndPages() async throws {
        let entry = Self.sampleEntry
        let provider = StubHistorySyncProvider(currentRevision: 42, entries: [entry])
        let router = IPhoneEndpointServer.makeRouter(
            health: { Self.readyHealth },
            transcribe: { _ in throw IPhoneEndpointFailure(.engineUnavailable) },
            history: { provider }
        )
        let application = Application(responder: router.buildResponder())
        let longCursor = String(repeating: "c", count: 65)

        try await application.test(.router) { client in
            try await client.execute(uri: "/v1/history/manifest", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                let object = try Self.jsonObject(response.body)
                #expect(object["revision"] as? Int == 42)
                #expect(object["entry_count"] as? Int == 1)
                #expect(object["pinned_count"] as? Int == 0)
                #expect(object["max_operations_per_request"] as? Int == 100)
                #expect(object["max_text_characters"] as? Int == 100_000)
                let retention = object["retention"] as? [String: Any]
                #expect(retention?["unpinned_days"] as? Int == 90)
                #expect(retention?["pinned"] as? String == "until_unpinned_or_deleted")
            }

            try await client.execute(uri: "/v1/history?revision=42", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                let object = try Self.jsonObject(response.body)
                #expect(object["revision"] as? Int == 42)
                #expect(object["next_cursor"] as? String == "118")
                let entries = object["entries"] as? [[String: Any]]
                #expect(entries?.count == 1)
                #expect(entries?.first?["id"] as? String == entry.id.uuidString.lowercased())
                #expect(entries?.first?["display_text"] as? String == "Edited copy")
                #expect(entries?.first?["source_kind"] as? String == "iphone_pwa")
                #expect(entries?.first?.keys.contains("destination_bundle_identifier") == false)
            }
            #expect(await provider.lastPageRequest?.limit == 100)

            try await client.execute(
                uri: "/v1/history?revision=42&cursor=118&limit=25",
                method: .get
            ) { response in
                #expect(response.status == .ok)
            }
            let recorded = await provider.lastPageRequest
            #expect(recorded?.cursor == "118")
            #expect(recorded?.limit == 25)

            try await client.execute(uri: "/v1/history", method: .get) { response in
                #expect(response.status == .badRequest)
                let object = try Self.jsonObject(response.body)
                #expect(object["error"] as? String == "invalid_request")
            }

            for uri in [
                "/v1/history?revision=-1",
                "/v1/history?revision=soon",
                "/v1/history?revision=42&limit=0",
                "/v1/history?revision=42&limit=101",
                "/v1/history?revision=42&limit=all",
                "/v1/history?revision=42&cursor=" + longCursor,
            ] {
                try await client.execute(uri: uri, method: .get) { response in
                    #expect(response.status == .badRequest)
                    #expect(response.headers[.cacheControl] == "no-store")
                }
            }

            try await client.execute(uri: "/v1/history?revision=41", method: .get) { response in
                #expect(response.status == .conflict)
                #expect(response.headers[.cacheControl] == "no-store")
                let object = try Self.jsonObject(response.body)
                #expect(object["error"] as? String == "history_changed")
                #expect(object["revision"] as? Int == 42)
            }
        }
    }

    @Test("operation batches are validated, decoded, and echoed back")
    func historyOperations() async throws {
        let provider = StubHistorySyncProvider(currentRevision: 42, entries: [Self.sampleEntry])
        let router = IPhoneEndpointServer.makeRouter(
            health: { Self.readyHealth },
            transcribe: { _ in throw IPhoneEndpointFailure(.engineUnavailable) },
            history: { provider }
        )
        let application = Application(responder: router.buildResponder())
        let opID = UUID()
        let entryID = UUID()
        let body = Self.makeImportBatch(opID: opID, entryID: entryID)

        try await application.test(.router) { client in
            try await client.execute(
                uri: "/v1/history/operations",
                method: .post,
                headers: [.contentType: "application/json; charset=utf-8"],
                body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                let object = try Self.jsonObject(response.body)
                #expect(object["revision"] as? Int == 43)
                let results = object["results"] as? [[String: Any]]
                #expect(results?.count == 1)
                #expect(results?.first?["op_id"] as? String == opID.uuidString.lowercased())
                #expect(results?.first?["status"] as? String == "applied")
            }

            let decoded = try #require(await provider.lastBatch?.operations.first)
            #expect(decoded.opID == opID)
            #expect(decoded.entryID == entryID)
            #expect(decoded.type == .import)
            #expect(decoded.sourceKind == .iphoneShortcut)
            #expect(decoded.mode == .clean)
            #expect(decoded.text == "Ship it.")
            #expect(decoded.route == "cloud_fallback")
            #expect(decoded.cleanup == "none")
            #expect(decoded.createdAt != nil)

            try await client.execute(
                uri: "/v1/history/operations",
                method: .post,
                headers: [.contentType: "text/plain"],
                body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .badRequest)
                let object = try Self.jsonObject(response.body)
                #expect(object["error"] as? String == "invalid_request")
            }

            try await client.execute(
                uri: "/v1/history/operations",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"operations":[]}"#)
            ) { response in
                #expect(response.status == .badRequest)
            }

            try await client.execute(
                uri: "/v1/history/operations",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: Self.makeDeleteBatch(count: 101))
            ) { response in
                #expect(response.status == .badRequest)
            }

            try await client.execute(
                uri: "/v1/history/operations",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: Self.makeDeleteBatch(count: 100))
            ) { response in
                #expect(response.status == .ok)
            }

            try await client.execute(
                uri: "/v1/history/operations",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"operations":["#)
            ) { response in
                #expect(response.status == .badRequest)
            }

            let oversized = String(repeating: "x", count: 2 * 1_024 * 1_024 + 64)
            try await client.execute(
                uri: "/v1/history/operations",
                method: .post,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: oversized)
            ) { response in
                #expect(response.status == .contentTooLarge)
                #expect(response.headers[.cacheControl] == "no-store")
                let object = try Self.jsonObject(response.body)
                #expect(object["error"] as? String == "payload_too_large")
            }
        }
    }

    @Test("live listener stops and restarts without relaunching the app")
    func liveListenerRestart() async throws {
        let port = 43_139
        let server = IPhoneEndpointServer(port: port)
        let health: IPhoneEndpointServer.HealthProvider = {
            IPhoneEndpointHealthResponse(
                ready: true,
                busy: false,
                selectedEngine: ASRSelection.parakeetV2.rawValue
            )
        }
        let transcribe: IPhoneEndpointServer.TranscriptionHandler = { request in
            IPhoneTranscriptionResponse(
                requestID: request.requestID,
                text: "unused",
                route: .macLocal,
                cleanup: .none,
                latencyMilliseconds: 0,
                fallbackReason: nil
            )
        }

        await server.start(
            health: health,
            transcribe: transcribe,
            stateChanged: { _ in }
        )
        try await Self.requireHealthyListener(port: port)

        await server.stop(stateChanged: { _ in })
        #expect(!(await Self.listenerResponds(port: port)))

        await server.start(
            health: health,
            transcribe: transcribe,
            stateChanged: { _ in }
        )
        try await Self.requireHealthyListener(port: port)
        await server.stop(stateChanged: { _ in })
        #expect(!(await Self.listenerResponds(port: port)))
    }

    @Test("response JSON uses the public snake-case contract")
    func responseContract() throws {
        let requestID = UUID()
        let response = IPhoneTranscriptionResponse(
            requestID: requestID,
            text: "Ship it.",
            route: .macLocal,
            cleanup: .deterministic,
            latencyMilliseconds: 842,
            fallbackReason: nil
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        )
        #expect(object["request_id"] as? String == requestID.uuidString.lowercased())
        #expect(object["text"] as? String == "Ship it.")
        #expect(object["route"] as? String == "mac_local")
        #expect(object["cleanup"] as? String == "deterministic")
        #expect(object["latency_ms"] as? Int == 842)
        #expect(object.keys.contains("fallback_reason"))

        let decoded = try JSONDecoder().decode(
            IPhoneTranscriptionResponse.self,
            from: JSONEncoder().encode(response)
        )
        #expect(decoded.requestID == requestID)
        #expect(decoded.text == response.text)
        #expect(decoded.route == response.route)
    }

    @Test("desktop inference preempts a remote lease")
    func desktopPreemptsRemote() async throws {
        let coordinator = InferenceLeaseCoordinator()
        let lease = try #require(coordinator.tryBeginRemote())
        let cancellation = CancellationProbe()
        lease.installCancellation { cancellation.markCancelled() }

        coordinator.beginDesktop()

        #expect(cancellation.cancelled)
        #expect(coordinator.tryBeginRemote() == nil)
        coordinator.endRemote(lease)
        try await coordinator.waitForRemoteRelease(timeout: .milliseconds(50))
        coordinator.endDesktop()
        #expect(coordinator.tryBeginRemote() != nil)
    }

    @Test("only one remote request can own inference")
    func remoteLeaseIsExclusive() throws {
        let coordinator = InferenceLeaseCoordinator()
        let first = try #require(coordinator.tryBeginRemote())
        #expect(coordinator.tryBeginRemote() == nil)
        coordinator.endRemote(first)
        #expect(coordinator.tryBeginRemote() != nil)
    }

    @Test("remote cleanup leaves commands literal when boundaries are unavailable")
    func remoteCommandsRequireBoundaries() async throws {
        let pipeline = CleanupPipeline(refiner: DeterministicRefiner())
        let transcript = FinalTranscript(text: "first new line second", boundaries: [])

        let result = try await pipeline.process(
            transcript,
            mode: .clean,
            commandsAllowed: false
        )

        #expect(result.text == "first new line second")
        #expect(result.metadata.recognizedCommands.isEmpty)
    }

    @Test("normalizer produces a 16 kHz mono WAV and removes both temporary files")
    func audioNormalizationAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPhoneEndpointTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let data = Self.makePCM16WAV(sampleRate: 48_000, duration: 0.2)

        let request = IPhoneTranscriptionRequest(
            requestID: UUID(),
            mode: .clean,
            allowsCloudFallback: true,
            claimedDurationSeconds: 0.2,
            mediaType: "audio/wav",
            audio: data
        )
        let normalized = try await RemoteAudioNormalizer(
            temporaryDirectory: directory
        ).normalize(request)
        let output = try AVAudioFile(forReading: normalized.wavURL)

        #expect(output.processingFormat.sampleRate == 16_000)
        #expect(output.processingFormat.channelCount == 1)
        #expect(normalized.durationSeconds > 0.19)
        #expect(FileManager.default.fileExists(atPath: normalized.inputURL.path))
        #expect(FileManager.default.fileExists(atPath: normalized.wavURL.path))

        normalized.removeFiles()
        #expect(!FileManager.default.fileExists(atPath: normalized.inputURL.path))
        #expect(!FileManager.default.fileExists(atPath: normalized.wavURL.path))
    }

    @Test("normalizer rejects empty payloads without leaving files")
    func emptyPayloadIsRejected() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPhoneEndpointTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestID = UUID()
        let request = IPhoneTranscriptionRequest(
            requestID: requestID,
            mode: .clean,
            allowsCloudFallback: false,
            claimedDurationSeconds: 1,
            mediaType: "audio/wav",
            audio: Data()
        )

        do {
            _ = try await RemoteAudioNormalizer(temporaryDirectory: directory).normalize(request)
            Issue.record("Expected empty audio to be rejected")
        } catch let error as RemoteAudioNormalizerError {
            #expect(error == .emptyAudio)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(contents.isEmpty)
    }

    private static let readyHealth = IPhoneEndpointHealthResponse(
        ready: true,
        busy: false,
        selectedEngine: ASRSelection.parakeetV2.rawValue
    )

    private static let sampleEntry = HistorySyncEntry(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: 1_757_180_400),
        updatedAt: Date(timeIntervalSince1970: 1_757_180_470),
        sourceKind: .iphonePWA,
        mode: .clean,
        rawText: "raw copy",
        polishedText: "polished copy",
        userEditedText: "Edited copy",
        displayText: "Edited copy",
        destinationDisplayName: nil,
        remoteRoute: "mac_local",
        cleanupBackend: "deterministic",
        isPinned: false,
        entryRevision: 3
    )

    private static func transcriptionHeaders(requestID: UUID = UUID()) -> HTTPFields {
        [
            .contentType: "audio/mp4",
            HTTPField.Name("X-Request-ID")!: requestID.uuidString,
            HTTPField.Name("X-Dictation-Mode")!: "clean",
            HTTPField.Name("X-Allow-Cloud-Fallback")!: "true",
            HTTPField.Name("X-Audio-Duration-Seconds")!: "1.5",
        ]
    }

    private static func jsonObject(_ body: ByteBuffer) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(body.readableBytesView)) as? [String: Any]
        )
    }

    private static func makeImportBatch(opID: UUID, entryID: UUID) -> String {
        let fields = [
            #""op_id":"\#(opID.uuidString.lowercased())""#,
            #""type":"import""#,
            #""entry_id":"\#(entryID.uuidString.lowercased())""#,
            #""created_at":"2026-09-06T17:20:00.000Z""#,
            #""source_kind":"iphone_shortcut""#,
            #""mode":"clean""#,
            #""text":"Ship it.""#,
            #""route":"cloud_fallback""#,
            #""cleanup":"none""#,
        ]
        return #"{"operations":[{\#(fields.joined(separator: ","))}]}"#
    }

    private static func makeDeleteBatch(count: Int) -> String {
        let operations = (0..<count).map { _ in
            let fields = [
                #""op_id":"\#(UUID().uuidString.lowercased())""#,
                #""type":"delete""#,
                #""entry_id":"\#(UUID().uuidString.lowercased())""#,
                #""base_revision":1"#,
            ]
            return #"{\#(fields.joined(separator: ","))}"#
        }
        return #"{"operations":[\#(operations.joined(separator: ","))]}"#
    }

    private static func makePCM16WAV(
        sampleRate: Double,
        duration: TimeInterval
    ) -> Data {
        let rate = UInt32(sampleRate.rounded())
        let frameCount = UInt32((sampleRate * duration).rounded())
        let audioByteCount = frameCount * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36) + audioByteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(rate)
        data.appendLittleEndian(rate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(audioByteCount)
        data.append(Data(count: Int(audioByteCount)))
        return data
    }

    private static func requireHealthyListener(port: Int) async throws {
        for _ in 0..<100 {
            if await listenerResponds(port: port) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ListenerTestError.didNotStart
    }

    private static func listenerResponds(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/healthz") else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0.2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

private enum ListenerTestError: Error {
    case didNotStart
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}

/// Records the decoded requests the router handed to the history seam so the
/// tests can assert on wire decoding without a real store.
private actor StubHistorySyncProvider: HistorySyncProviding {
    private let currentRevision: Int64
    private let entries: [HistorySyncEntry]
    private(set) var lastPageRequest: (revision: Int64, cursor: String?, limit: Int)?
    private(set) var lastBatch: HistorySyncOperationBatch?

    init(currentRevision: Int64, entries: [HistorySyncEntry]) {
        self.currentRevision = currentRevision
        self.entries = entries
    }

    func manifest() async throws -> HistorySyncManifest {
        HistorySyncManifest(
            revision: currentRevision,
            entryCount: entries.count,
            pinnedCount: entries.filter(\.isPinned).count,
            retention: .standard(unpinnedDays: 90),
            maxOperationsPerRequest: HistorySyncManifest.maximumOperationsPerRequest,
            maxTextCharacters: HistorySyncManifest.maximumTextCharacters
        )
    }

    func page(revision: Int64, cursor: String?, limit: Int) async throws -> HistorySyncPage {
        lastPageRequest = (revision, cursor, limit)
        guard revision == currentRevision else {
            throw HistorySyncError.historyChanged(currentRevision: currentRevision)
        }
        return HistorySyncPage(revision: currentRevision, entries: entries, nextCursor: "118")
    }

    func apply(
        _ batch: HistorySyncOperationBatch
    ) async throws -> HistorySyncOperationBatchResult {
        lastBatch = batch
        return HistorySyncOperationBatchResult(
            revision: currentRevision + 1,
            results: batch.operations.map {
                HistorySyncOperationResult(opID: $0.opID, status: .applied, entry: nil)
            }
        )
    }
}

private final class ClientProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [IPhoneDictationClient] = []

    var last: IPhoneDictationClient? {
        lock.withLock { clients.last }
    }

    var callCount: Int {
        lock.withLock { clients.count }
    }

    func record(_ client: IPhoneDictationClient) {
        lock.withLock { clients.append(client) }
    }
}

private final class DiagnosticProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [IPhoneEndpointDiagnosticEvent] = []

    var events: [IPhoneEndpointDiagnosticEvent] {
        lock.withLock { values }
    }

    func record(_ event: IPhoneEndpointDiagnosticEvent) {
        lock.withLock { values.append(event) }
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var cancelled: Bool {
        lock.withLock { value }
    }

    func markCancelled() {
        lock.withLock { value = true }
    }
}
