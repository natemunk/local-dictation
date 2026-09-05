import Foundation
import Testing
@testable import LocalDictation

@Suite("Cleanup commands and pipeline")
struct CleanupPipelineTests {
    @Test("sentence-bounded line and paragraph commands are deterministic")
    func lineAndParagraphCommands() {
        let result = CleanupCommandProcessor().process(
            "first. new line. second. new paragraph. third"
        )

        #expect(result.text == "first.\nsecond.\n\nthird")
        #expect(result.recognizedCommands.map(\.kind) == [.newLine, .newParagraph])
    }

    @Test("embedded command phrases remain literal and are recorded")
    func embeddedCommandsRemainLiteral() {
        let processor = CleanupCommandProcessor()

        for phrase in ["the new line of products", "scratch that idea"] {
            let result = processor.process(phrase)

            #expect(result.text == phrase)
            #expect(result.recognizedCommands.isEmpty)
            #expect(result.unrecognizedCommandCandidates.map(\.phrase) == [
                phrase == "the new line of products" ? "new line" : "scratch that"
            ])
        }
    }

    @Test("commands without an internal boundary are not inferred from prose")
    func commandsRequireStandaloneSpans() {
        let processor = CleanupCommandProcessor()
        let ambiguous = processor.process("first new line second")
        #expect(ambiguous.text == "first new line second")
        #expect(ambiguous.recognizedCommands.isEmpty)
        #expect(ambiguous.unrecognizedCommandCandidates.map(\.phrase) == ["new line"])

        let raw = "first new line second"
        let command = transcriptBoundary(raw, around: "new line")
        let commandEnd = transcriptBoundary(raw, around: "new line", atEnd: true)
        let bounded = processor.process(
            FinalTranscript(text: raw, boundaries: [command, commandEnd])
        )
        #expect(bounded.text == "first\nsecond")
        #expect(bounded.recognizedCommands.map(\.kind) == [.newLine])

        let metadataOnly = processor.analyze(
            FinalTranscript(text: raw, boundaries: [command, commandEnd])
        )
        #expect(metadataOnly.text == raw)
        #expect(metadataOnly.recognizedCommands.map(\.kind) == [.newLine])
    }

    @Test("scratch that needs a nonempty bounded phrase")
    func scratchThat() {
        let processor = CleanupCommandProcessor()

        let noPriorPhrase = processor.process("scratch that")
        #expect(noPriorPhrase.text == "scratch that")
        #expect(noPriorPhrase.recognizedCommands.isEmpty)
        #expect(noPriorPhrase.unrecognizedCommandCandidates.map(\.phrase) == ["scratch that"])

        let embedded = processor.process("Tuesday scratch that Wednesday")
        #expect(embedded.text == "Tuesday scratch that Wednesday")
        #expect(embedded.recognizedCommands.isEmpty)
        #expect(embedded.unrecognizedCommandCandidates.map(\.phrase) == ["scratch that"])

        let boundedRaw = "Keep this. remove me scratch that replacement"
        let command = transcriptBoundary(boundedRaw, around: "scratch that")
        let commandEnd = transcriptBoundary(boundedRaw, around: "scratch that", atEnd: true)
        let removeMe = transcriptBoundary(boundedRaw, around: "remove me")
        let bounded = processor.process(
            FinalTranscript(
                text: boundedRaw,
                boundaries: [removeMe, command, commandEnd]
            )
        )
        #expect(bounded.text == "Keep this. replacement")
        #expect(bounded.recognizedCommands.map(\.kind) == [.scratchThat])

        #expect(
            processor.process("Keep this. remove me. scratch that. replacement").text
                == "Keep this. replacement"
        )
    }

    @Test("scratch that uses an ASR pause boundary without punctuation")
    func scratchThatUsesASRPauseBoundary() async throws {
        let raw = "keep this remove me scratch that replacement"
        let command = transcriptBoundary(raw, around: "scratch that")
        let commandEnd = transcriptBoundary(raw, around: "scratch that", atEnd: true)
        let removeMe = transcriptBoundary(raw, around: "remove me")
        let transcript = FinalTranscript(
            text: raw,
            language: "en",
            boundaries: [removeMe, command, commandEnd]
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
            "Keep this. remove me. scratch that. replacement",
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

        let forwardRaw = "bullet list apples new line oranges"
        let forward = processor.process(
            FinalTranscript(
                text: forwardRaw,
                boundaries: [
                    transcriptBoundary(forwardRaw, around: "bullet list", atEnd: true),
                    transcriptBoundary(forwardRaw, around: "new line"),
                    transcriptBoundary(forwardRaw, around: "new line", atEnd: true),
                ]
            )
        )
        #expect(forward.text == "- apples\n- oranges")
        #expect(forward.recognizedCommands.map(\.kind) == [.bulletList, .newLine])

        let retroactive = processor.process("apples. oranges. make that a bullet list")
        #expect(retroactive.text == "- apples.\n- oranges.")
        #expect(retroactive.recognizedCommands.map(\.kind) == [.makeThatABulletList])
    }

    @Test("a standalone command does not leave an orphan bullet marker")
    func standaloneBulletCommandsDoNotLeaveOrphans() {
        let processor = CleanupCommandProcessor()

        for command in ["bullet list", "make that a bullet list"] {
            let result = processor.process(command)
            #expect(result.text.isEmpty)
            #expect(!result.text.contains("-"))
        }

        let sequence = "bullet list new line"
        let sequenceResult = processor.process(
            FinalTranscript(
                text: sequence,
                boundaries: [
                    transcriptBoundary(sequence, around: "bullet list", atEnd: true),
                    transcriptBoundary(sequence, around: "new line"),
                ]
            )
        )
        #expect(sequenceResult.text.isEmpty)
        #expect(!sequenceResult.text.contains("-"))
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

    @Test("malformed protected expressions fail without a forced regex crash")
    func malformedProtectedExpression() {
        let processor = CleanupVocabularyProcessor(
            protectedPatterns: [
                CleanupProtectedPattern(name: "broken", expression: "[")
            ]
        )

        #expect(throws: CleanupVocabularyError.self) {
            try processor.process("safe transcript")
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
        #expect(try validator.validate(generated: source, against: input) == source)

        do {
            try validator.validate(generated: "• \(source)", against: input)
            Issue.record("Expected inferred bullet formatting to be rejected")
        } catch let failure as RefinementValidationFailure {
            guard case .inferredBulletFormatting = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
        }

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

    @Test("repetition cleanup requires horizontal whitespace and skips numbers")
    func conservativeRepetitionDetection() async throws {
        let pipeline = CleanupPipeline()
        let unchanged = [
            "a big, big problem",
            "a big; big problem",
            "a big\nbig problem",
            "room 3 3",
        ]

        for source in unchanged {
            let result = try await pipeline.process(source, mode: .clean)
            #expect(result.text == source)
            #expect(!result.metadata.candidateDisfluencies.contains { $0.kind == .repetition })
        }

        let removed = try await pipeline.process("we we should ship", mode: .clean)
        #expect(removed.text == "we should ship")
        #expect(removed.metadata.candidateDisfluencies.map(\.text) == ["we"])
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
        #expect(result.metadata.recognizedCommands.isEmpty)
        #expect(result.metadata.unrecognizedCommandCandidates.map(\.phrase) == [
            "bullet list", "make that bold"
        ])
        #expect(result.metadata.candidateDisfluencies.isEmpty)
    }

    @Test("clean mode executes commands and removes only high-confidence filler")
    func deterministicCleanMode() async throws {
        let pipeline = CleanupPipeline()

        let result = try await pipeline.process(
            "um. bullet list. alpha. new line. beta beta",
            mode: .clean
        )

        #expect(result.text == "- alpha.\n- beta")
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

    @Test("deterministic cleanup removes orphan punctuation after filler deletion")
    func deterministicPunctuationCleanup() async throws {
        let pipeline = CleanupPipeline()

        let cases = [
            ("um, we should ship.", "we should ship."),
            ("we should um., ship", "we should ship."),
            ("um uh, we should ship.", "we should ship."),
            ("um, \"we should ship.\"", "\"we should ship.\""),
            ("um, (we should ship).", "(we should ship)."),
        ]

        for (source, expected) in cases {
            let result = try await pipeline.process(source, mode: .clean)
            #expect(result.text == expected)
        }
    }

    @Test("accepted model output receives safe punctuation normalization")
    func acceptedModelOutputGetsSafePunctuationNormalization() async throws {
        let pipeline = CleanupPipeline(
            refiner: FixedCleanupRefiner(output: "we should ., ship")
        )

        let result = try await pipeline.process("we should um., ship", mode: .clean)

        #expect(result.text == "we should ship.")
        #expect(result.outcome == .accepted)
    }

    @Test("one enclosing code fence is unwrapped after output normalization")
    func wholeResponseFenceIsUnwrapped() async throws {
        let pipeline = CleanupPipeline(
            refiner: FixedCleanupRefiner(
                output: "\u{FEFF}```text\r\nwe should ship\r\n```\r\n"
            )
        )

        let result = try await pipeline.process("we should ship", mode: .clean)

        #expect(result.text == "we should ship")
        #expect(result.outcome == .accepted)
    }

    @Test("preambles and malformed fences reject the whole model output")
    func modelWrappersFailClosed() async throws {
        for output in [
            "Here is the cleaned text: we should ship",
            "Result:\n```text\nwe should ship\n```",
            "```text\nwe should ship\n```\n```",
            "we\u{202E} should ship",
            String(repeating: ".", count: 5_000) + "we should ship",
        ] {
            let result = try await CleanupPipeline(
                refiner: FixedCleanupRefiner(output: output)
            ).process("we should ship", mode: .clean)

            #expect(result.text == "we should ship")
            guard case .deterministicFallback = result.outcome else {
                Issue.record("Expected model output wrapper rejection for \(output)")
                continue
            }
        }
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

    @Test("a rejected deterministic fallback returns the normalized input")
    func rejectedDeterministicFallbackReturnsInput() async throws {
        let pipeline = CleanupPipeline(refiner: FixedCleanupRefiner(output: "-"))

        let result = try await pipeline.process("bullet list. um", mode: .clean)

        #expect(result.text == "- um")
        #expect(result.metadata.recognizedCommands.map(\.kind) == [.bulletList])
        guard case let .deterministicFallback(.validationFailure(failure)) = result.outcome else {
            Issue.record("Expected a validation-triggered deterministic fallback")
            return
        }
        #expect(failure == .explicitBulletFormattingRemoved)
    }

    @Test("cleanup executor does not block MainActor while deterministic work runs")
    @MainActor
    func cleanupExecutorLeavesMainActorResponsive() async throws {
        let probe = BlockingCleanupProbe()
        let executor = CleanupExecutor()
        let pipeline = CleanupPipeline(refiner: BlockingCleanupRefiner(probe: probe))

        let cleanup = Task { @MainActor in
            try await executor.process(
                pipeline,
                transcript: FinalTranscript(text: "we should ship"),
                mode: .clean
            )
        }
        await Task.yield()
        probe.release()

        let result = try await cleanup.value
        #expect(!probe.didTimeOut)
        #expect(result.text == "we should ship")
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

private final class BlockingCleanupProbe: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func wait() {
        guard semaphore.wait(timeout: .now() + 1) == .timedOut else { return }
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    func release() {
        semaphore.signal()
    }
}

private struct BlockingCleanupRefiner: TextRefiner {
    let probe: BlockingCleanupProbe

    func refine(_ input: TextRefinementInput) async throws -> String {
        probe.wait()
        return input.transcript
    }
}

private func transcriptBoundary(
    _ text: String,
    around phrase: String,
    atEnd: Bool = false,
    source: TranscriptBoundarySource = .pause
) -> TranscriptBoundary {
    let range = text.range(of: phrase)!
    let byteRange = CleanupText.byteRange(in: text, for: range)
    return TranscriptBoundary(
        utf8Offset: atEnd ? byteRange.upperBound : byteRange.lowerBound,
        source: source
    )
}
