import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleFoundationRefinerUnavailableReason: Equatable, Sendable {
    case unsupportedOperatingSystem
    case frameworkUnavailable
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case systemModelUnavailable(String)
}
enum AppleFoundationModelAvailability: Equatable, Sendable {
    case available
    case unavailable(AppleFoundationRefinerUnavailableReason)
}

enum AppleFoundationRefinerError: Error, Equatable, CustomStringConvertible, Sendable {
    case unavailable(AppleFoundationRefinerUnavailableReason)

    var description: String {
        switch self {
        case let .unavailable(reason):
            switch reason {
            case .unsupportedOperatingSystem:
                return "Apple Foundation Models cleanup requires macOS 26 or newer."
            case .frameworkUnavailable:
                return "The FoundationModels framework is unavailable in this build."
            case .deviceNotEligible:
                return "This device is not eligible for the system language model."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is not enabled."
            case .modelNotReady:
                return "The system language model is not ready."
            case let .systemModelUnavailable(reason):
                return "The system language model is unavailable: \(reason)"
            }
        }
    }
}

/// Injection seam for availability and session creation. Implementations receive
/// exactly two strings: static rules and the finalized transcript.
protocol AppleFoundationModelAdapter: Sendable {
    func availability() -> AppleFoundationModelAvailability
    func generate(transcript: String, staticRules: String) async throws -> String
}

struct AppleFoundationRefiner: TextRefiner, Sendable {
    private let adapter: any AppleFoundationModelAdapter
    private let deadline: Duration
    private let platformSupportsFoundationModels: @Sendable () -> Bool

    init(
        adapter: any AppleFoundationModelAdapter = SystemAppleFoundationModelAdapter(),
        deadline: Duration = CleanupDeadline.standard,
        platformSupportsFoundationModels: @escaping @Sendable () -> Bool = {
            if #available(macOS 26.0, *) { return true }
            return false
        }
    ) {
        self.adapter = adapter
        self.deadline = deadline
        self.platformSupportsFoundationModels = platformSupportsFoundationModels
    }

    func refine(_ input: TextRefinementInput) async throws -> String {
        guard platformSupportsFoundationModels() else {
            throw AppleFoundationRefinerError.unavailable(.unsupportedOperatingSystem)
        }
        switch adapter.availability() {
        case .available:
            break
        case let .unavailable(reason):
            throw AppleFoundationRefinerError.unavailable(reason)
        }

        let transcript = input.transcript
        let rules = CleanupRefinementRules.text(for: input)
        return try await CleanupDeadline.run(for: deadline) { [adapter] in
            try await adapter.generate(
                transcript: transcript,
                staticRules: rules
            )
        }
    }
}

struct SystemAppleFoundationModelAdapter: AppleFoundationModelAdapter, Sendable {
    func availability() -> AppleFoundationModelAvailability {
        guard #available(macOS 26.0, *) else {
            return .unavailable(.unsupportedOperatingSystem)
        }
        #if canImport(FoundationModels)
        return availabilityOnSupportedSystem()
        #else
        return .unavailable(.frameworkUnavailable)
        #endif
    }

    func generate(transcript: String, staticRules: String) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw AppleFoundationRefinerError.unavailable(.unsupportedOperatingSystem)
        }
        #if canImport(FoundationModels)
        return try await generateOnSupportedSystem(
            transcript: transcript,
            staticRules: staticRules
        )
        #else
        throw AppleFoundationRefinerError.unavailable(.frameworkUnavailable)
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func availabilityOnSupportedSystem() -> AppleFoundationModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady):
            return .unavailable(.modelNotReady)
        @unknown default:
            return .unavailable(.systemModelUnavailable("unknown availability state"))
        }
    }

    @available(macOS 26.0, *)
    private func generateOnSupportedSystem(
        transcript: String,
        staticRules: String
    ) async throws -> String {
        switch availabilityOnSupportedSystem() {
        case .available:
            break
        case let .unavailable(reason):
            throw AppleFoundationRefinerError.unavailable(reason)
        }

        let session = LanguageModelSession(
            model: .default,
            tools: [],
            instructions: staticRules
        )
        return try await session.respond(to: transcript).content
    }
    #endif
}
