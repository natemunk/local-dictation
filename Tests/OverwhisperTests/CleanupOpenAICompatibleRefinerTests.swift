import Foundation
import Testing
@testable import LocalDictation

@Suite("OpenAI-compatible cleanup refiner", .serialized)
struct CleanupOpenAICompatibleRefinerTests {
    @Test("request body contains only protocol fields, static rules, and transcript")
    func privacyRequestBody() async throws {
        let recorder = CleanupRequestRecorder()
        CleanupURLProtocolStub.install { request in
            recorder.record(request)
            return stubResponse(
                for: request,
                body: #"{"choices":[{"message":{"role":"assistant","content":"OpenRouter"}}]}"#
            )
        }
        defer { CleanupURLProtocolStub.reset() }

        let refiner = OpenAICompatibleRefiner(
            configuration: OpenAICompatibleRefinerConfiguration(
                endpoint: URL(string: "http://127.0.0.1:8080/v1/chat/completions")!,
                model: "local-cleaner",
                apiKey: "TOP_SECRET_API_KEY"
            ),
            session: stubbedSession()
        )
        let input = TextRefinementInput(
            transcript: "OpenRouter um",
            candidateDisfluencies: [
                CleanupDisfluencyCandidate(
                    kind: .filler,
                    confidence: .high,
                    text: "PRIVATE_CANDIDATE_METADATA",
                    range: CleanupTextRange(11, 13)
                )
            ],
            protectedSpans: [
                CleanupProtectedSpan(
                    name: "PRIVATE_PROTECTED_METADATA",
                    text: "OpenRouter",
                    range: CleanupTextRange(0, 10)
                )
            ]
        )

        #expect(try await refiner.refine(input) == "OpenRouter")
        let request = try #require(recorder.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TOP_SECRET_API_KEY")

        let body = try #require(recorder.body)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(Set(object.keys) == ["messages", "model", "stream", "temperature"])
        #expect(object["model"] as? String == "local-cleaner")
        let messages = try #require(object["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0] == [
            "role": "system",
            "content": CleanupRefinementRules.text(for: input),
        ])
        #expect(messages[1] == ["role": "user", "content": "OpenRouter um"])

        let bodyText = String(decoding: body, as: UTF8.self)
        #expect(!bodyText.contains("PRIVATE_CANDIDATE_METADATA"))
        #expect(!bodyText.contains("PRIVATE_PROTECTED_METADATA"))
        #expect(!bodyText.contains("TOP_SECRET_API_KEY"))
        #expect(!bodyText.contains("candidateDisfluencies"))
        #expect(!bodyText.contains("protectedSpans"))
        #expect(bodyText.contains("UTF-8 bytes 11..<13"))
    }

    @Test("malformed chat-completion responses fail clearly")
    func malformedResponse() async {
        CleanupURLProtocolStub.install { request in
            stubResponse(for: request, body: #"{"choices":[]}"#)
        }
        defer { CleanupURLProtocolStub.reset() }
        let refiner = OpenAICompatibleRefiner(
            configuration: OpenAICompatibleRefinerConfiguration(
                endpoint: URL(string: "http://localhost:8080/v1/chat/completions")!,
                model: "local-cleaner"
            ),
            session: stubbedSession()
        )

        do {
            _ = try await refiner.refine(emptyNetworkInput("hello"))
            Issue.record("Expected malformed response")
        } catch let error as OpenAICompatibleRefinerError {
            #expect(error == .malformedResponse)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("remote endpoints require opt-in and HTTPS")
    func remotePolicy() async {
        let recorder = CleanupRequestRecorder()
        CleanupURLProtocolStub.install { request in
            recorder.record(request)
            return stubResponse(
                for: request,
                body: #"{"choices":[{"message":{"role":"assistant","content":"hello"}}]}"#
            )
        }
        defer { CleanupURLProtocolStub.reset() }

        let blocked = OpenAICompatibleRefiner(
            configuration: OpenAICompatibleRefinerConfiguration(
                endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
                model: "cleaner"
            ),
            session: stubbedSession()
        )
        do {
            _ = try await blocked.refine(emptyNetworkInput("hello"))
            Issue.record("Expected remote policy rejection")
        } catch let error as OpenAICompatibleRefinerError {
            #expect(error == .remoteEndpointNotAllowed("api.example.com"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(recorder.request == nil)

        let loopbackLookalike = OpenAICompatibleRefiner(
            configuration: OpenAICompatibleRefinerConfiguration(
                endpoint: URL(string: "https://127.attacker.example/v1/chat/completions")!,
                model: "cleaner"
            ),
            session: stubbedSession()
        )
        do {
            _ = try await loopbackLookalike.refine(emptyNetworkInput("hello"))
            Issue.record("Expected lookalike loopback host rejection")
        } catch let error as OpenAICompatibleRefinerError {
            #expect(error == .remoteEndpointNotAllowed("127.attacker.example"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let insecure = OpenAICompatibleRefiner(
            configuration: OpenAICompatibleRefinerConfiguration(
                endpoint: URL(string: "http://api.example.com/v1/chat/completions")!,
                model: "cleaner",
                allowRemote: true
            ),
            session: stubbedSession()
        )
        do {
            _ = try await insecure.refine(emptyNetworkInput("hello"))
            Issue.record("Expected insecure remote policy rejection")
        } catch let error as OpenAICompatibleRefinerError {
            #expect(error == .insecureRemoteEndpoint("api.example.com"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let allowed = OpenAICompatibleRefiner(
            configuration: OpenAICompatibleRefinerConfiguration(
                endpoint: URL(string: "https://api.example.com/v1/chat/completions")!,
                model: "cleaner",
                allowRemote: true
            ),
            session: stubbedSession()
        )
        let allowedResult = try? await allowed.refine(emptyNetworkInput("hello"))
        #expect(allowedResult == "hello")
        #expect(recorder.request?.url?.host == "api.example.com")
    }

    @Test("deadline helper cancels a slow operation")
    func deadline() async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await CleanupDeadline.run(for: .milliseconds(20)) {
                try await Task.sleep(for: .seconds(5))
                return "late"
            }
            Issue.record("Expected deadline failure")
        } catch let error as CleanupDeadlineError {
            #expect(error == .exceeded)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(start.duration(to: clock.now) < .seconds(1))
    }
}

private func emptyNetworkInput(_ transcript: String) -> TextRefinementInput {
    TextRefinementInput(transcript: transcript, candidateDisfluencies: [], protectedSpans: [])
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CleanupURLProtocolStub.self]
    return URLSession(configuration: configuration)
}

private func stubResponse(for request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(body.utf8))
}

private final class CleanupRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedBody: Data?

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    var body: Data? {
        lock.withLock { storedBody }
    }

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        lock.withLock {
            storedRequest = request
            storedBody = body
        }
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                return count == 0 ? data : nil
            }
        }
    }
}

private final class CleanupURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.withLock { Self.handler = handler }
    }

    static func reset() {
        lock.withLock { handler = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try Self.lock.withLock { () throws -> Handler in
                guard let handler = Self.handler else {
                    throw URLError(.resourceUnavailable)
                }
                return handler
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
