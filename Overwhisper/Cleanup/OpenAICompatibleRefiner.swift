import Foundation

struct OpenAICompatibleRefinerConfiguration: Equatable, Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String?
    let allowRemote: Bool
    let deadline: Duration

    init(
        endpoint: URL,
        model: String,
        apiKey: String? = nil,
        allowRemote: Bool = false,
        deadline: Duration = CleanupDeadline.standard
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.allowRemote = allowRemote
        self.deadline = deadline
    }

    func endpointDisposition() throws -> OpenAICompatibleEndpointDisposition {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAICompatibleRefinerError.emptyModel
        }
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              ["http", "https"].contains(scheme),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw OpenAICompatibleRefinerError.invalidEndpoint(
                "use an absolute HTTP(S) URL without credentials, query, or fragment"
            )
        }
        guard components.path == "/v1/chat/completions" else {
            throw OpenAICompatibleRefinerError.invalidEndpointPath(components.path)
        }

        if Self.isLoopbackHost(host) {
            return .loopback
        }
        guard allowRemote else {
            throw OpenAICompatibleRefinerError.remoteEndpointNotAllowed(host)
        }
        guard scheme == "https" else {
            throw OpenAICompatibleRefinerError.insecureRemoteEndpoint(host)
        }
        return .remoteAllowed
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = UInt8(octets[0]),
              octets.dropFirst().allSatisfy({ UInt8($0) != nil })
        else { return false }
        return first == 127
    }
}

enum OpenAICompatibleEndpointDisposition: Equatable, Sendable {
    case loopback
    case remoteAllowed
}

enum OpenAICompatibleRefinerError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidEndpoint(String)
    case invalidEndpointPath(String)
    case remoteEndpointNotAllowed(String)
    case insecureRemoteEndpoint(String)
    case emptyModel
    case invalidHTTPResponse
    case httpStatus(Int)
    case malformedResponse

    var description: String {
        switch self {
        case let .invalidEndpoint(reason):
            "The refinement endpoint is invalid: \(reason)"
        case let .invalidEndpointPath(path):
            "The refinement endpoint path must be exactly /v1/chat/completions, not '\(path)'."
        case let .remoteEndpointNotAllowed(host):
            "Remote refinement endpoint '\(host)' is blocked; set allowRemote only after explicit user opt-in."
        case let .insecureRemoteEndpoint(host):
            "Remote refinement endpoint '\(host)' must use HTTPS."
        case .emptyModel:
            "The OpenAI-compatible model name is empty."
        case .invalidHTTPResponse:
            "The refinement endpoint did not return an HTTP response."
        case let .httpStatus(status):
            "The refinement endpoint returned HTTP \(status)."
        case .malformedResponse:
            "The refinement endpoint response is missing choices[0].message.content."
        }
    }
}

/// A minimal OpenAI-compatible text generator. It sends no app context,
/// protected-span metadata, vocabulary list, or history. Allowed deletion
/// ranges are derived exclusively from the transcript sent in the same request.
final class OpenAICompatibleRefiner: TextRefiner, @unchecked Sendable {
    private let configuration: OpenAICompatibleRefinerConfiguration
    private let session: URLSession
    private let redirectDelegate = CleanupRedirectBlockingDelegate()

    init(
        configuration: OpenAICompatibleRefinerConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    func refine(_ input: TextRefinementInput) async throws -> String {
        try validateConfiguration()

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty
        {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: configuration.model,
                messages: [
                    ChatMessage(
                        role: "system",
                        content: CleanupRefinementRules.text(for: input)
                    ),
                    ChatMessage(role: "user", content: input.transcript),
                ],
                temperature: 0,
                stream: false
            )
        )
        let frozenRequest = request

        let (data, response) = try await CleanupDeadline.run(for: configuration.deadline) { [session, redirectDelegate] in
            try await session.data(for: frozenRequest, delegate: redirectDelegate)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICompatibleRefinerError.invalidHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAICompatibleRefinerError.httpStatus(httpResponse.statusCode)
        }
        guard let response = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let content = response.choices.first?.message.content
        else {
            throw OpenAICompatibleRefinerError.malformedResponse
        }
        return content
    }

    private func validateConfiguration() throws {
        _ = try configuration.endpointDisposition()
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let stream: Bool
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
    }
}

private final class CleanupRedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
