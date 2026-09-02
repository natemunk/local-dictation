import Foundation

enum RefinementValidationFailure: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidCandidateRange(CleanupTextRange)
    case invalidProtectedRange(name: String, range: CleanupTextRange)
    case protectedSpanSourceMismatch(name: String, range: CleanupTextRange)
    case overlappingProtectedSpans(first: String, second: String)
    case protectedSpanCountMismatch(name: String, text: String, expected: Int, actual: Int)
    case protectedSpanOrderChanged(name: String, text: String)
    case inferredBulletFormatting
    case explicitBulletFormattingRemoved
    case unexpectedLexicalToken(token: String, outputTokenIndex: Int)
    case deletionOutsideCandidate(token: String, sourceRange: CleanupTextRange)
    case excessiveLexicalDeletion(deleted: Int, sourceTokenCount: Int, maximumAllowed: Int)

    var description: String {
        switch self {
        case let .invalidCandidateRange(range):
            "Candidate disfluency range \(range.lowerBound)..<\(range.upperBound) is not a valid UTF-8 range in the source transcript."
        case let .invalidProtectedRange(name, range):
            "Protected span '\(name)' has an invalid UTF-8 range \(range.lowerBound)..<\(range.upperBound)."
        case let .protectedSpanSourceMismatch(name, range):
            "Protected span '\(name)' does not byte-match the source at \(range.lowerBound)..<\(range.upperBound)."
        case let .overlappingProtectedSpans(first, second):
            "Protected spans '\(first)' and '\(second)' overlap, so an exact ordered alignment is ambiguous."
        case let .protectedSpanCountMismatch(name, text, expected, actual):
            "Protected span '\(name)' was not preserved byte-identically exactly once per source occurrence: expected \(expected) occurrence(s) of '\(text)', found \(actual)."
        case let .protectedSpanOrderChanged(name, text):
            "Protected span '\(name)' ('\(text)') was reordered."
        case .inferredBulletFormatting:
            "Output introduced bullet formatting without an explicit bullet command in the normalized source."
        case .explicitBulletFormattingRemoved:
            "Output removed bullet formatting produced by an explicit bullet command."
        case let .unexpectedLexicalToken(token, outputTokenIndex):
            "Output lexical token #\(outputTokenIndex + 1) ('\(token)') is not a case-insensitive, in-order source token; additions, substitutions, and reordering are forbidden."
        case let .deletionOutsideCandidate(token, sourceRange):
            "Source token '\(token)' at UTF-8 bytes \(sourceRange.lowerBound)..<\(sourceRange.upperBound) was deleted outside every candidate disfluency range."
        case let .excessiveLexicalDeletion(deleted, sourceTokenCount, maximumAllowed):
            "Cleanup deleted \(deleted) of \(sourceTokenCount) lexical tokens; the conservative limit is \(maximumAllowed) (two-token grace, then 20%, capped at 8 tokens)."
        }
    }
}

struct RefinementValidator: Sendable {
    /// Validates generated text against the exact text sent to a refiner.
    /// Returns the generated text unchanged when it is accepted.
    @discardableResult
    func validate(generated: String, against input: TextRefinementInput) throws -> String {
        try validateRanges(in: input)
        try validateBulletFormatting(generated: generated, input: input)
        try validateProtectedSpans(generated: generated, input: input)
        try validateLexicalAlignment(generated: generated, input: input)
        return generated
    }

    private func validateBulletFormatting(
        generated: String,
        input: TextRefinementInput
    ) throws {
        let sourceHasBullets = containsBulletLine(input.transcript)
        let outputHasBullets = containsBulletLine(generated)
        if !sourceHasBullets, outputHasBullets {
            throw RefinementValidationFailure.inferredBulletFormatting
        }
        if sourceHasBullets, !outputHasBullets {
            throw RefinementValidationFailure.explicitBulletFormattingRemoved
        }
    }

    private func containsBulletLine(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return trimmed.hasPrefix("- ")
                || trimmed.hasPrefix("* ")
                || trimmed.hasPrefix("• ")
        }
    }

    private func validateRanges(in input: TextRefinementInput) throws {
        for candidate in input.candidateDisfluencies {
            guard CleanupText.stringRange(in: input.transcript, for: candidate.range) != nil else {
                throw RefinementValidationFailure.invalidCandidateRange(candidate.range)
            }
        }

        let sorted = input.protectedSpans.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound < $1.range.upperBound
        }
        for (index, span) in sorted.enumerated() {
            guard let sourceText = CleanupText.substring(in: input.transcript, range: span.range),
                  !span.range.isEmpty
            else {
                throw RefinementValidationFailure.invalidProtectedRange(name: span.name, range: span.range)
            }
            guard Array(sourceText.utf8) == Array(span.text.utf8) else {
                throw RefinementValidationFailure.protectedSpanSourceMismatch(
                    name: span.name,
                    range: span.range
                )
            }
            if index > 0, sorted[index - 1].range.overlaps(span.range) {
                throw RefinementValidationFailure.overlappingProtectedSpans(
                    first: sorted[index - 1].name,
                    second: span.name
                )
            }
        }
    }

    private func validateProtectedSpans(generated: String, input: TextRefinementInput) throws {
        let sorted = input.protectedSpans.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound < $1.range.upperBound
        }
        guard !sorted.isEmpty else { return }

        let outputBytes = Array(generated.utf8)
        var matchesByText: [Data: [CleanupTextRange]] = [:]
        for span in sorted {
            let key = Data(span.text.utf8)
            guard matchesByText[key] == nil else { continue }
            let expected = protectedOccurrenceCount(of: span.text, in: sorted)
            let matches = atomicMatches(
                of: span.text,
                in: generated,
                outputBytes: outputBytes
            )
            let actual = matches.count
            guard expected == actual else {
                throw RefinementValidationFailure.protectedSpanCountMismatch(
                    name: span.name,
                    text: span.text,
                    expected: expected,
                    actual: actual
                )
            }
            matchesByText[key] = matches
        }

        var cursor = 0
        for span in sorted {
            let key = Data(span.text.utf8)
            guard let matches = matchesByText[key],
                  let match = matches.first(where: { $0.lowerBound >= cursor })
            else {
                throw RefinementValidationFailure.protectedSpanOrderChanged(
                    name: span.name,
                    text: span.text
                )
            }
            cursor = match.upperBound
        }
    }

    /// Counts declared protected occurrences plus atomic occurrences nested
    /// inside another declared protected span. A ticket identifier can, for
    /// example, be protected once on its own and once as part of a protected
    /// URL without making unchanged output look like a duplicate.
    private func protectedOccurrenceCount(
        of text: String,
        in protectedSpans: [CleanupProtectedSpan]
    ) -> Int {
        protectedSpans.reduce(into: 0) { count, container in
            count += atomicMatches(
                of: text,
                in: container.text,
                outputBytes: Array(container.text.utf8)
            ).count
        }
    }

    /// Finds byte-identical, non-overlapping occurrences while treating a
    /// lexical protected term as one atomic span. For example, `API` is not an
    /// occurrence inside `APIs`, so a longer neighboring identifier cannot
    /// create a false duplicate-count failure.
    private func atomicMatches(
        of text: String,
        in generated: String,
        outputBytes: [UInt8]
    ) -> [CleanupTextRange] {
        let needle = Array(text.utf8)
        guard !needle.isEmpty else { return [] }

        var result: [CleanupTextRange] = []
        var cursor = 0
        while let offset = firstOffset(
            of: needle,
            in: outputBytes,
            startingAt: cursor
        ) {
            let range = CleanupTextRange(offset, offset + needle.count)
            if let stringRange = CleanupText.stringRange(in: generated, for: range),
               isAtomic(stringRange, protectedText: text, in: generated)
            {
                result.append(range)
                cursor = range.upperBound
            } else {
                cursor = offset + 1
            }
        }
        return result
    }

    private func isAtomic(
        _ range: Range<String.Index>,
        protectedText: String,
        in generated: String
    ) -> Bool {
        if protectedText.first.map(isLexicalBoundaryCharacter) == true,
           range.lowerBound > generated.startIndex
        {
            let previous = generated[generated.index(before: range.lowerBound)]
            if isLexicalBoundaryCharacter(previous) { return false }
        }
        if protectedText.last.map(isLexicalBoundaryCharacter) == true,
           range.upperBound < generated.endIndex,
           isLexicalBoundaryCharacter(generated[range.upperBound])
        {
            return false
        }
        return true
    }

    private func isLexicalBoundaryCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private func validateLexicalAlignment(generated: String, input: TextRefinementInput) throws {
        let source = CleanupText.lexicalTokens(in: input.transcript)
        let output = CleanupText.lexicalTokens(in: generated)

        // A normal subsequence scan gives the clearest addition/substitution/
        // reorder failure before deletion permissions are considered.
        var sourceCursor = 0
        for (outputIndex, outputToken) in output.enumerated() {
            while sourceCursor < source.count,
                  source[sourceCursor].canonical != outputToken.canonical
            {
                sourceCursor += 1
            }
            guard sourceCursor < source.count else {
                throw RefinementValidationFailure.unexpectedLexicalToken(
                    token: outputToken.text,
                    outputTokenIndex: outputIndex
                )
            }
            sourceCursor += 1
        }

        let isDeletable = source.map { token in
            input.candidateDisfluencies.contains { $0.range.contains(token.range) }
        }
        if let invalidDeletion = minimumCostInvalidDeletion(
            source: source,
            output: output,
            isDeletable: isDeletable
        ) {
            throw RefinementValidationFailure.deletionOutsideCandidate(
                token: invalidDeletion.text,
                sourceRange: invalidDeletion.range
            )
        }

        let deletedTokenCount = source.count - output.count
        let maximumAllowed = CleanupDeletionLimit.maximumAllowedTokenCount(
            sourceTokenCount: source.count
        )
        guard deletedTokenCount <= maximumAllowed else {
            throw RefinementValidationFailure.excessiveLexicalDeletion(
                deleted: deletedTokenCount,
                sourceTokenCount: source.count,
                maximumAllowed: maximumAllowed
            )
        }
    }

    /// Finds an optimal source/output alignment. Candidate deletions cost zero;
    /// every other deletion costs one. A nil result means a zero-cost alignment
    /// exists, including ambiguous repeated-token cases.
    private func minimumCostInvalidDeletion(
        source: [CleanupLexicalToken],
        output: [CleanupLexicalToken],
        isDeletable: [Bool]
    ) -> CleanupLexicalToken? {
        let width = output.count + 1
        let cellCount = (source.count + 1) * width
        let unreachable = Int32.max / 4
        var costs = Array(repeating: unreachable, count: cellCount)
        var predecessor = Array(repeating: UInt8(0), count: cellCount)
        costs[0] = 0

        func offset(_ sourceIndex: Int, _ outputIndex: Int) -> Int {
            sourceIndex * width + outputIndex
        }

        for sourceIndex in 0..<source.count {
            for outputIndex in 0...output.count {
                let currentOffset = offset(sourceIndex, outputIndex)
                let currentCost = costs[currentOffset]
                guard currentCost < unreachable else { continue }

                let deletionCost: Int32 = isDeletable[sourceIndex] ? 0 : 1
                let deletionOffset = offset(sourceIndex + 1, outputIndex)
                if currentCost + deletionCost < costs[deletionOffset] {
                    costs[deletionOffset] = currentCost + deletionCost
                    predecessor[deletionOffset] = 1
                }

                if outputIndex < output.count,
                   source[sourceIndex].canonical == output[outputIndex].canonical
                {
                    let matchOffset = offset(sourceIndex + 1, outputIndex + 1)
                    // Prefer a match on ties so diagnostics do not blame an
                    // avoidable deletion of a repeated required token.
                    if currentCost <= costs[matchOffset] {
                        costs[matchOffset] = currentCost
                        predecessor[matchOffset] = 2
                    }
                }
            }
        }

        let finalCost = costs[offset(source.count, output.count)]
        guard finalCost > 0, finalCost < unreachable else { return nil }

        var sourceIndex = source.count
        var outputIndex = output.count
        var invalid: [CleanupLexicalToken] = []
        while sourceIndex > 0 {
            switch predecessor[offset(sourceIndex, outputIndex)] {
            case 1:
                sourceIndex -= 1
                if !isDeletable[sourceIndex] { invalid.append(source[sourceIndex]) }
            case 2:
                sourceIndex -= 1
                outputIndex -= 1
            default:
                // The relaxed subsequence check above guarantees reachability.
                return source.first
            }
        }
        return invalid.min { $0.range.lowerBound < $1.range.lowerBound }
    }

    private func firstOffset(
        of needle: [UInt8],
        in haystack: [UInt8],
        startingAt start: Int
    ) -> Int? {
        guard !needle.isEmpty,
              start >= 0,
              start <= haystack.count,
              needle.count <= haystack.count - start
        else { return nil }

        let lastStart = haystack.count - needle.count
        guard start <= lastStart else { return nil }
        for offset in start...lastStart where haystack[offset..<(offset + needle.count)].elementsEqual(needle) {
            return offset
        }
        return nil
    }
}

private extension CleanupTextRange {
    var isEmpty: Bool { lowerBound == upperBound }
}
