import Testing
@testable import LocalDictation

@Suite("Profile formatting refiner")
struct CleanupProfileFormattingRefinerTests {
    @Test("paragraph profiles remove inferred bullets and extra paragraphs")
    func paragraphProfileConstraints() async throws {
        let refiner = ProfileFormattingRefiner(
            base: FormattingStubRefiner(output: "One\n\n- two\n- three"),
            allowInferredBullets: false,
            preserveParagraphBreakCount: true
        )
        let result = try await refiner.refine(
            TextRefinementInput(
                transcript: "One two three",
                candidateDisfluencies: [],
                protectedSpans: []
            )
        )
        #expect(result == "One\ntwo\nthree")
    }

    @Test("explicit source bullets and paragraphs remain available")
    func explicitFormattingSurvives() async throws {
        let refiner = ProfileFormattingRefiner(
            base: FormattingStubRefiner(output: "- One\n- two\n\nThree"),
            allowInferredBullets: false,
            preserveParagraphBreakCount: true
        )
        let result = try await refiner.refine(
            TextRefinementInput(
                transcript: "- One\n- two\n\nThree",
                candidateDisfluencies: [],
                protectedSpans: []
            )
        )
        #expect(result == "- One\n- two\n\nThree")
    }
}

private struct FormattingStubRefiner: TextRefiner {
    let output: String

    func refine(_ input: TextRefinementInput) async throws -> String {
        output
    }
}
