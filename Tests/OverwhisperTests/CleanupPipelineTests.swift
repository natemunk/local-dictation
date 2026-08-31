import Foundation
import Testing
@testable import LocalDictation

@Suite("Cleanup commands and pipeline")
struct CleanupPipelineTests {
    @Test("explicit line and paragraph commands are deterministic")
    func lineAndParagraphCommands() {
        let result = CleanupCommandProcessor().process(
            "first new line second new paragraph third"
        )

        #expect(result.text == "first\nsecond\n\nthird")
        #expect(result.recognizedCommands.map(\.kind) == [.newLine, .newParagraph])
    }

    @Test("scratch that replaces only the latest deterministic segment")
    func scratchThat() {
        let processor = CleanupCommandProcessor()

        #expect(processor.process("Tuesday scratch that Wednesday").text == "Wednesday")
        #expect(
            processor.process("Keep this. remove me scratch that replacement").text
                == "Keep this. replacement"
        )
    }

    @Test("scratch that uses an ASR pause boundary without punctuation")
    func scratchThatUsesASRPauseBoundary() async throws {
        let raw = "keep this remove me scratch that replacement"
        let transcript = FinalTranscript(
            text: raw,
            language: "en",
            boundaries: [
                TranscriptBoundary(
                    utf8Offset: "keep this ".utf8.count,
                    source: .pause
                )
            ]
        )
        let pipeline = CleanupPipeline()

        let cleaned = try await pipeline.process(transcript, mode: .clean)
        let literal = try await pipeline.process(transcript, mode: .literal)

        #expect(cleaned.text == "keep this replacement")
        #expect(literal.text == raw)
        #expect(literal.outcome == .skippedLiteralMode)
    }

    @Test("scratch that falls back to the previous sentence boundary")
    func scratchThatUsesSentenceFallback() async throws {
        let result = try await CleanupPipeline().process(
            "Keep this. remove me scratch that replacement",
            mode: .clean
        )

        #expect(result.text == "Keep this. replacement")
    }

    @Test("timed boundaries map to the trimmed transcript safely")
    func timedBoundariesMapAfterTrimming() {
        let boundaries = TranscriptBoundaryMapper.pauseBoundaries(
            in: "keep this remove me",
            fragments: [
                TimedTranscriptFragment(text: " keep this", startTime: 0, endTime: 0.8),
                TimedTranscriptFragment(text: " remove me", startTime: 1.4, endTime: 2.0),
            ]
        )

        #expect(
            boundaries == [
                TranscriptBoundary(utf8Offset: "keep this".utf8.count, source: .pause)
            ]
        )
        #expect(
            TranscriptBoundaryMapper.pauseBoundaries(
                in: "different text",
                fragments: [
                    TimedTranscriptFragment(text: " keep this", startTime: 0, endTime: 0.8),
                    TimedTranscriptFragment(text: " remove me", startTime: 1.4, endTime: 2.0),
                ]
            ).isEmpty
        )
    }

    @Test("returned ASR segments create stable phrase boundaries")
    func segmentBoundariesMapFromTimestamps() {
        let boundaries = TranscriptBoundaryMapper.segmentBoundaries(
            in: "first phrase second phrase",
            fragments: [
                TimedTranscriptFragment(text: " first phrase", startTime: 0, endTime: 1.0),
                TimedTranscriptFragment(text: " second phrase", startTime: 1.0, endTime: 2.0),
            ]
        )

        #expect(
            boundaries == [
                TranscriptBoundary(utf8Offset: "first phrase".utf8.count, source: .segment)
            ]
        )
    }

    @Test("forward and retroactive bullet commands have distinct behavior")
    func bulletCommands() {
        let processor = CleanupCommandProcessor()

        let forward = processor.process("bullet list apples new line oranges")
        #expect(forward.text == "- apples\n- oranges")
        #expect(forward.recognizedCommands.map(\.kind) == [.bulletList, .newLine])

        let retroactive = processor.process("apples. oranges. make that a bullet list")
        #expect(retroactive.text == "- apples.\n- oranges.")
        #expect(retroactive.recognizedCommands.map(\.kind) == [.makeThatABulletList])
    }

    @Test("unsupported command-like phrases remain text and become metadata")
    func unsupportedCommandMetadata() {
        let result = CleanupCommandProcessor().process("please make that bold today")

        #expect(result.text == "please make that bold today")
        #expect(result.recognizedCommands.isEmpty)
        #expect(result.unrecognizedCommandCandidates.count == 1)
        #expect(result.unrecognizedCommandCandidates.first?.phrase == "make that bold")
    }

    @Test("vocabulary uses longest nonoverlapping replacements and protects output")
    func vocabularyReplacementAndProtection() throws {
        let processor = CleanupVocabularyProcessor(
            replacements: [
                CleanupVocabularyReplacement(spokenForm: "open router", writtenForm: "OpenRouter"),
                CleanupVocabularyReplacement(spokenForm: "router", writtenForm: "ROUTER"),
            ]
        )

        let result = try processor.process("OPEN ROUTER at nate@example.com")

        #expect(result.text == "OpenRouter at nate@example.com")
        #expect(result.appliedReplacements.count == 1)
        #expect(result.appliedReplacements.first?.writtenForm == "OpenRouter")
        #expect(result.protectedSpans.map(\.text) == ["OpenRouter", "nate@example.com"])
        for span in result.protectedSpans {
            #expect(CleanupText.substring(in: result.text, range: span.range) == span.text)
        }
    }

    @Test("standard patterns protect paths tickets acronyms and identifiers without overlaps")
    func standardProtectedPatterns() throws {
        let source = #"MYE-2076 keeps AI and D196 at "/Users/nmunk/Library/Application Support/LocalDictation/config.toml"; cache ~/Library/Caches/LocalDictation; use URLSession, TextRefiner, and allow_remote."#
        let vocabulary = try CleanupVocabularyProcessor().process(source)
        let expectedProtectedText = [
            "MYE-2076",
            "AI",
            "D196",
            "/Users/nmunk/Library/Application Support/LocalDictation/config.toml",
            "~/Library/Caches/LocalDictation",
            "URLSession",
            "TextRefiner",
            "allow_remote",
        ]

        #expect(vocabulary.protectedSpans.map(\.text) == expectedProtectedText)
        for (previous, next) in zip(
            vocabulary.protectedSpans,
            vocabulary.protectedSpans.dropFirst()
        ) {
            #expect(!previous.range.overlaps(next.range))
            #expect(previous.range.upperBound <= next.range.lowerBound)
        }

        let input = TextRefinementInput(
            transcript: source,
            candidateDisfluencies: [],
            protectedSpans: vocabulary.protectedSpans
        )
        let validator = RefinementValidator()
        #expect(try validator.validate(generated: "• \(source)", against: input) == "• \(source)")

        do {
            try validator.validate(
                generated: source.replacingOccurrences(of: "MYE-2076", with: "MYE-2077"),
                against: input
            )
            Issue.record("Expected ticket byte-identity failure")
        } catch let failure as RefinementValidationFailure {
            guard case .protectedSpanCountMismatch = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
        }

        do {
            try validator.validate(generated: source + " AI", against: input)
            Issue.record("Expected acronym exact-count failure")
        } catch let failure as RefinementValidationFailure {
            guard case .protectedSpanCountMismatch = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
        }

        do {
            try validator.validate(
                generated: source.replacingOccurrences(
                    of: "URLSession, TextRefiner",
                    with: "TextRefiner, URLSession"
                ),
                against: input
            )
            Issue.record("Expected identifier ordering failure")
        } catch let failure as RefinementValidationFailure {
            guard case .protectedSpanOrderChanged = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
        }
    }

    @Test("disfluency detection emits ranges without touching protected spans")
    func candidateDisfluencyRanges() {
        let text = "Um, we we should, you know, continue."
        let detector = CleanupDisfluencyDetector()
        let candidates = detector.candidates(in: text)

        #expect(candidates.map(\.text) == ["Um", "we", "you know"])
        #expect(candidates.map(\.kind) == [.filler, .repetition, .discourseMarker])
        #expect(candidates.map(\.confidence) == [.high, .high, .possible])
        for candidate in candidates {
            #expect(CleanupText.substring(in: text, range: candidate.range) == candidate.text)
        }

        let protectedRange = CleanupTextRange(4, 9)
        let protected = CleanupProtectedSpan(name: "intentional", text: "we we", range: protectedRange)
        #expect(detector.candidates(in: text, excluding: [protected]).map(\.text) == ["Um", "you know"])
    }

    @Test("literal mode keeps commands and filler, applies vocabulary, and skips the refiner")
    func literalMode() async throws {
        let pipeline = CleanupPipeline(
            vocabularyReplacements: [
                CleanupVocabularyReplacement(spokenForm: "open router", writtenForm: "OpenRouter")
            ],
            refiner: ExplodingCleanupRefiner()
        )

        let result = try await pipeline.process(
            "um bullet list open router make that bold",
            mode: .literal
        )

        #expect(result.text == "um bullet list OpenRouter make that bold")
        #expect(result.outcome == .skippedLiteralMode)
        #expect(result.metadata.recognizedCommands.map(\.kind) == [.bulletList])
        #expect(result.metadata.unrecognizedCommandCandidates.map(\.phrase) == ["make that bold"])
        #expect(result.metadata.candidateDisfluencies.isEmpty)
    }

    @Test("clean mode executes commands and removes only high-confidence filler")
    func deterministicCleanMode() async throws {
        let pipeline = CleanupPipeline()

        let result = try await pipeline.process(
            "um bullet list alpha new line beta beta",
            mode: .clean
        )

        #expect(result.text == "- alpha\n- beta")
        #expect(result.outcome == .accepted)
        #expect(result.metadata.recognizedCommands.map(\.kind) == [.bulletList, .newLine])
        #expect(result.metadata.candidateDisfluencies.map(\.text) == ["um", "beta"])
    }

    @Test("deterministic cleanup stays inside the deletion-volume limit")
    func deterministicDeletionLimit() async throws {
        let pipeline = CleanupPipeline()
        let result = try await pipeline.process(
            "um uh erm one two three four five six seven eight nine ten eleven",
            mode: .clean
        )

        #expect(result.text == "erm one two three four five six seven eight nine ten eleven")
        #expect(result.outcome == .accepted)
        #expect(result.metadata.candidateDisfluencies.map(\.text) == ["um", "uh", "erm"])
    }

    @Test("invalid generated text falls back deterministically with the validation failure")
    func invalidGenerationFallsBack() async throws {
        let pipeline = CleanupPipeline(refiner: FixedCleanupRefiner(output: "we definitely should ship"))

        let result = try await pipeline.process("we should ship", mode: .clean)

        #expect(result.text == "we should ship")
        guard case let .deterministicFallback(.validationFailure(failure)) = result.outcome else {
            Issue.record("Expected a validation-triggered deterministic fallback")
            return
        }
        guard case let .unexpectedLexicalToken(token, _) = failure else {
            Issue.record("Expected an unexpected lexical token failure")
            return
        }
        #expect(token == "definitely")
    }
}

private struct FixedCleanupRefiner: TextRefiner {
    let output: String

    func refine(_ input: TextRefinementInput) async throws -> String {
        output
    }
}

private struct ExplodingCleanupRefiner: TextRefiner {
    struct UnexpectedCall: Error {}

    func refine(_ input: TextRefinementInput) async throws -> String {
        throw UnexpectedCall()
    }
}
