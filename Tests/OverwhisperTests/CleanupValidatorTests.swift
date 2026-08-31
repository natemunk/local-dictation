import Foundation
import Testing
@testable import LocalDictation

@Suite("Cleanup refinement validator")
struct CleanupValidatorTests {
    private let validator = RefinementValidator()

    @Test("case punctuation apostrophes whitespace line breaks and bullets are permitted")
    func formattingOnlyChanges() throws {
        let source = "dont ship um OpenRouter today"
        let input = TextRefinementInput(
            transcript: source,
            candidateDisfluencies: [candidate("um", in: source)],
            protectedSpans: [protected("OpenRouter", in: source)]
        )

        let generated = "• Don't ship OpenRouter\nTODAY!"
        #expect(try validator.validate(generated: generated, against: input) == generated)
    }

    @Test("a lexical deletion is allowed only inside a candidate range")
    func deletionBoundary() throws {
        let source = "we really should ship"
        let allowed = TextRefinementInput(
            transcript: source,
            candidateDisfluencies: [candidate("really", in: source)],
            protectedSpans: []
        )
        #expect(try validator.validate(generated: "we should ship", against: allowed) == "we should ship")

        let forbidden = TextRefinementInput(
            transcript: source,
            candidateDisfluencies: [],
            protectedSpans: []
        )
        do {
            try validator.validate(generated: "we should ship", against: forbidden)
            Issue.record("Expected a deletion-outside-candidate failure")
        } catch let failure as RefinementValidationFailure {
            guard case let .deletionOutsideCandidate(token, _) = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
            #expect(token == "really")
        }
    }

    @Test("candidate deletion is accepted at and rejected above the ratio boundary")
    func deletionRatioBoundary() throws {
        let accepted = deletionVolumeFixture(sourceTokenCount: 15, deletedTokenCount: 3)
        #expect(
            try validator.validate(generated: accepted.generated, against: accepted.input)
                == accepted.generated
        )

        let rejected = deletionVolumeFixture(sourceTokenCount: 14, deletedTokenCount: 3)
        do {
            try validator.validate(generated: rejected.generated, against: rejected.input)
            Issue.record("Expected excessive ratio deletion failure")
        } catch let failure as RefinementValidationFailure {
            guard case let .excessiveLexicalDeletion(deleted, sourceCount, maximumAllowed) = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
            #expect(deleted == 3)
            #expect(sourceCount == 14)
            #expect(maximumAllowed == 2)
        }
    }

    @Test("candidate deletion is accepted at and rejected above the absolute boundary")
    func deletionAbsoluteBoundary() throws {
        let accepted = deletionVolumeFixture(sourceTokenCount: 40, deletedTokenCount: 8)
        #expect(
            try validator.validate(generated: accepted.generated, against: accepted.input)
                == accepted.generated
        )

        let rejected = deletionVolumeFixture(sourceTokenCount: 50, deletedTokenCount: 9)
        do {
            try validator.validate(generated: rejected.generated, against: rejected.input)
            Issue.record("Expected excessive absolute deletion failure")
        } catch let failure as RefinementValidationFailure {
            guard case let .excessiveLexicalDeletion(deleted, sourceCount, maximumAllowed) = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
            #expect(deleted == 9)
            #expect(sourceCount == 50)
            #expect(maximumAllowed == 8)
        }
    }

    @Test("alignment handles repeated-token ambiguity")
    func repeatedTokenAlignment() throws {
        let source = "go go now"
        let input = TextRefinementInput(
            transcript: source,
            candidateDisfluencies: [candidate("go", occurrence: 0, in: source)],
            protectedSpans: []
        )

        #expect(try validator.validate(generated: "go now", against: input) == "go now")
    }

    @Test(
        "additions substitutions and reorderings are rejected",
        arguments: [
            (source: "we ship", generated: "we really ship", unexpected: "really"),
            (source: "we ship", generated: "we send", unexpected: "send"),
            (source: "we ship today", generated: "ship we today", unexpected: "we"),
        ]
    )
    func forbiddenLexicalChanges(example: (source: String, generated: String, unexpected: String)) {
        let input = TextRefinementInput(
            transcript: example.source,
            candidateDisfluencies: [],
            protectedSpans: []
        )

        do {
            try validator.validate(generated: example.generated, against: input)
            Issue.record("Expected an unexpected-token failure")
        } catch let failure as RefinementValidationFailure {
            guard case let .unexpectedLexicalToken(token, _) = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
            #expect(token == example.unexpected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("protected spans must remain byte-identical")
    func protectedByteIdentity() {
        let source = "use OpenRouter now"
        let input = TextRefinementInput(
            transcript: source,
            candidateDisfluencies: [],
            protectedSpans: [protected("OpenRouter", in: source)]
        )

        do {
            try validator.validate(generated: "use openrouter now", against: input)
            Issue.record("Expected protected byte-identity failure")
        } catch let failure as RefinementValidationFailure {
            guard case let .protectedSpanCountMismatch(_, text, expected, actual) = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
            #expect(text == "OpenRouter")
            #expect(expected == 1)
            #expect(actual == 0)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("protected spans must appear once each and in source order")
    func protectedCountAndOrder() {
        let source = "Alpha then Beta"
        let spans = [protected("Alpha", in: source), protected("Beta", in: source)]
        let input = TextRefinementInput(
            transcript: source,
            candidateDisfluencies: [],
            protectedSpans: spans
        )

        do {
            try validator.validate(generated: "Beta then Alpha", against: input)
            Issue.record("Expected protected ordering failure")
        } catch let failure as RefinementValidationFailure {
            guard case .protectedSpanOrderChanged = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try validator.validate(generated: "Alpha Alpha then Beta", against: input)
            Issue.record("Expected protected count failure")
        } catch let failure as RefinementValidationFailure {
            guard case let .protectedSpanCountMismatch(name, _, expected, actual) = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
            #expect(name == "test")
            #expect(expected == 1)
            #expect(actual == 2)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private func candidate(
    _ needle: String,
    occurrence: Int = 0,
    in source: String
) -> CleanupDisfluencyCandidate {
    let range = byteRange(of: needle, occurrence: occurrence, in: source)
    return CleanupDisfluencyCandidate(
        kind: .filler,
        confidence: .high,
        text: needle,
        range: range
    )
}

private func protected(_ needle: String, in source: String) -> CleanupProtectedSpan {
    CleanupProtectedSpan(name: "test", text: needle, range: byteRange(of: needle, in: source))
}

private func deletionVolumeFixture(
    sourceTokenCount: Int,
    deletedTokenCount: Int
) -> (input: TextRefinementInput, generated: String) {
    let tokens = (0..<sourceTokenCount).map { "token\($0)" }
    let source = tokens.joined(separator: " ")
    let candidates = tokens.prefix(deletedTokenCount).map { candidate($0, in: source) }
    return (
        TextRefinementInput(
            transcript: source,
            candidateDisfluencies: candidates,
            protectedSpans: []
        ),
        tokens.dropFirst(deletedTokenCount).joined(separator: " ")
    )
}

private func byteRange(
    of needle: String,
    occurrence: Int = 0,
    in source: String
) -> CleanupTextRange {
    var searchStart = source.startIndex
    var found: Range<String.Index>?
    for _ in 0...occurrence {
        found = source.range(of: needle, range: searchStart..<source.endIndex)
        guard let found else { fatalError("Missing test fixture substring: \(needle)") }
        searchStart = found.upperBound
    }
    return CleanupText.byteRange(in: source, for: found!)
}
