import Foundation

enum CleanupPipelineError: Error, Equatable, CustomStringConvertible, Sendable {
    case deterministicFallbackRejected(RefinementValidationFailure)

    var description: String {
        switch self {
        case let .deterministicFallbackRejected(failure):
            "The deterministic cleanup fallback violated its validator contract: \(failure.description)"
        }
    }
}

/// The integration boundary for finalized transcript segments.
///
/// Literal mode still applies explicit vocabulary corrections, but it never
/// executes spoken commands, removes filler, reformats text, or invokes a
/// refiner. Clean mode performs every stage and validates generated text before
/// accepting it.
struct CleanupPipeline: Sendable {
    private let commandProcessor: CleanupCommandProcessor
    private let vocabularyProcessor: CleanupVocabularyProcessor
    private let disfluencyDetector: CleanupDisfluencyDetector
    private let refiner: any TextRefiner
    private let deterministicFallback: DeterministicRefiner
    private let validator: RefinementValidator

    init(
        vocabularyReplacements: [CleanupVocabularyReplacement] = [],
        protectedPatterns: [CleanupProtectedPattern] = CleanupProtectedPattern.standard,
        refiner: any TextRefiner = DeterministicRefiner()
    ) {
        self.commandProcessor = CleanupCommandProcessor()
        self.vocabularyProcessor = CleanupVocabularyProcessor(
            replacements: vocabularyReplacements,
            protectedPatterns: protectedPatterns
        )
        self.disfluencyDetector = CleanupDisfluencyDetector()
        self.refiner = refiner
        self.deterministicFallback = DeterministicRefiner()
        self.validator = RefinementValidator()
    }

    func process(_ transcript: String, mode: CleanupMode) async throws -> CleanupResult {
        try await process(FinalTranscript(text: transcript), mode: mode)
    }

    func process(_ transcript: FinalTranscript, mode: CleanupMode) async throws -> CleanupResult {
        switch mode {
        case .literal:
            let commandAnalysis = commandProcessor.analyze(transcript.text)
            let vocabulary = try vocabularyProcessor.process(transcript.text)
            return CleanupResult(
                text: vocabulary.text,
                metadata: CleanupMetadata(
                    recognizedCommands: commandAnalysis.recognizedCommands,
                    unrecognizedCommandCandidates: commandAnalysis.unrecognizedCommandCandidates,
                    vocabularyReplacements: vocabulary.appliedReplacements,
                    protectedSpans: vocabulary.protectedSpans,
                    candidateDisfluencies: []
                ),
                outcome: .skippedLiteralMode
            )

        case .clean:
            let commands = commandProcessor.process(transcript)
            let vocabulary = try vocabularyProcessor.process(commands.text)
            let candidates = disfluencyDetector.candidates(
                in: vocabulary.text,
                excluding: vocabulary.protectedSpans
            )
            let input = TextRefinementInput(
                transcript: vocabulary.text,
                candidateDisfluencies: candidates,
                protectedSpans: vocabulary.protectedSpans
            )
            let metadata = CleanupMetadata(
                recognizedCommands: commands.recognizedCommands,
                unrecognizedCommandCandidates: commands.unrecognizedCommandCandidates,
                vocabularyReplacements: vocabulary.appliedReplacements,
                protectedSpans: vocabulary.protectedSpans,
                candidateDisfluencies: candidates
            )

            do {
                let generated = try await refiner.refine(input)
                do {
                    try validator.validate(generated: generated, against: input)
                    let normalized = deterministicFallback.normalizeAccepted(
                        generated,
                        preserving: input.protectedSpans
                    )
                    try validator.validate(generated: normalized, against: input)
                    return CleanupResult(text: normalized, metadata: metadata, outcome: .accepted)
                } catch let failure as RefinementValidationFailure {
                    return try await fallbackResult(
                        input: input,
                        metadata: metadata,
                        reason: .validationFailure(failure)
                    )
                }
            } catch {
                return try await fallbackResult(
                    input: input,
                    metadata: metadata,
                    reason: .refinerFailure(String(describing: error))
                )
            }
        }
    }

    private func fallbackResult(
        input: TextRefinementInput,
        metadata: CleanupMetadata,
        reason: CleanupFallbackReason
    ) async throws -> CleanupResult {
        let fallback = try await deterministicFallback.refine(input)
        do {
            try validator.validate(generated: fallback, against: input)
        } catch let failure as RefinementValidationFailure {
            throw CleanupPipelineError.deterministicFallbackRejected(failure)
        }
        return CleanupResult(
            text: fallback,
            metadata: metadata,
            outcome: .deterministicFallback(reason)
        )
    }
}
