import Foundation
import Testing
@testable import LocalDictation

@Suite("Apple Foundation refiner contract")
struct CleanupAppleFoundationRefinerTests {
    @Test("macOS versions before 26 report unavailable without opening a session")
    func unsupportedOperatingSystem() async {
        let adapter = RecordingAppleFoundationAdapter(availability: .available, output: "unused")
        let refiner = AppleFoundationRefiner(
            adapter: adapter,
            platformSupportsFoundationModels: { false }
        )

        do {
            _ = try await refiner.refine(emptyInput("hello"))
            Issue.record("Expected an unsupported-operating-system error")
        } catch let error as AppleFoundationRefinerError {
            #expect(error == .unavailable(.unsupportedOperatingSystem))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(adapter.calls.isEmpty)
    }

    @Test("Apple Intelligence and system-model unavailability are explicit")
    func modelUnavailable() async {
        let reasons: [AppleFoundationRefinerUnavailableReason] = [
            .deviceNotEligible,
            .appleIntelligenceNotEnabled,
            .modelNotReady,
        ]

        for reason in reasons {
            let adapter = RecordingAppleFoundationAdapter(
                availability: .unavailable(reason),
                output: "unused"
            )
            let refiner = AppleFoundationRefiner(
                adapter: adapter,
                platformSupportsFoundationModels: { true }
            )
            do {
                _ = try await refiner.refine(emptyInput("hello"))
                Issue.record("Expected an unavailable error for \(reason)")
            } catch let error as AppleFoundationRefinerError {
                #expect(error == .unavailable(reason))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(adapter.calls.isEmpty)
        }
    }

    @Test("the adapter receives only static rules and transcript text")
    func privacyBoundary() async throws {
        let adapter = RecordingAppleFoundationAdapter(availability: .available, output: "OpenRouter")
        let refiner = AppleFoundationRefiner(
            adapter: adapter,
            platformSupportsFoundationModels: { true }
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
        #expect(adapter.calls.count == 1)
        #expect(adapter.calls.first?.transcript == "OpenRouter um")
        #expect(adapter.calls.first?.staticRules == CleanupRefinementRules.text(for: input))
        #expect(!adapter.calls.first!.staticRules.contains("PRIVATE_"))
        #expect(adapter.calls.first!.staticRules.contains("UTF-8 bytes 11..<13"))
    }
}
private func emptyInput(_ transcript: String) -> TextRefinementInput {
    TextRefinementInput(
        transcript: transcript,
        candidateDisfluencies: [],
        protectedSpans: []
    )
}

private final class RecordingAppleFoundationAdapter: AppleFoundationModelAdapter, @unchecked Sendable {
    struct Call: Equatable {
        let transcript: String
        let staticRules: String
    }

    private let lock = NSLock()
    private let configuredAvailability: AppleFoundationModelAvailability
    private let output: String
    private var recordedCalls: [Call] = []

    init(availability: AppleFoundationModelAvailability, output: String) {
        self.configuredAvailability = availability
        self.output = output
    }

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func availability() -> AppleFoundationModelAvailability {
        configuredAvailability
    }

    func generate(transcript: String, staticRules: String) async throws -> String {
        lock.withLock {
            recordedCalls.append(Call(transcript: transcript, staticRules: staticRules))
        }
        return output
    }
}
