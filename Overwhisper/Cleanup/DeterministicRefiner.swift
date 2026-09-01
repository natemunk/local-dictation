import Foundation

enum CleanupDeadlineError: Error, Equatable, CustomStringConvertible, Sendable {
    case exceeded

    var description: String {
        "Text cleanup exceeded its deadline."
    }
}

enum CleanupDeadline {
    static let standard: Duration = .seconds(2)

    static func run<Value: Sendable>(
        for duration: Duration = standard,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: duration)
                try Task.checkCancellation()
                throw CleanupDeadlineError.exceeded
            }

            do {
                guard let value = try await group.next() else {
                    throw CleanupDeadlineError.exceeded
                }
                group.cancelAll()
                return value
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}

enum DeterministicRefinerError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidCandidateRange(CleanupTextRange)

    var description: String {
        switch self {
        case let .invalidCandidateRange(range):
            "Cannot deterministically remove invalid UTF-8 range \(range.lowerBound)..<\(range.upperBound)."
        }
    }
}

/// A conservative, offline fallback. It removes only high-confidence ranges
/// and applies punctuation/whitespace normalization without changing words.
struct DeterministicRefiner: TextRefiner, Sendable {
    func refine(_ input: TextRefinementInput) async throws -> String {
        let protectedRanges = input.protectedSpans.map(\.range)
        let candidates = input.candidateDisfluencies
            .filter { candidate in
                candidate.confidence == .high
                    && !protectedRanges.contains(where: { $0.overlaps(candidate.range) })
            }
            .sorted {
                if $0.range.lowerBound != $1.range.lowerBound {
                    return $0.range.lowerBound < $1.range.lowerBound
                }
                return $0.range.upperBound < $1.range.upperBound
            }

        let lexicalTokens = CleanupText.lexicalTokens(in: input.transcript)
        let deletionLimit = CleanupDeletionLimit.maximumAllowedTokenCount(
            sourceTokenCount: lexicalTokens.count
        )
        var selectedRanges: [CleanupTextRange] = []
        var selectedTokenIndexes: Set<Int> = []
        for candidate in candidates {
            guard CleanupText.stringRange(in: input.transcript, for: candidate.range) != nil else {
                throw DeterministicRefinerError.invalidCandidateRange(candidate.range)
            }
            guard selectedRanges.last.map({ !$0.overlaps(candidate.range) }) ?? true else { continue }
            let candidateTokenIndexes = Set(
                lexicalTokens.indices.filter { candidate.range.contains(lexicalTokens[$0].range) }
            )
            guard selectedTokenIndexes.union(candidateTokenIndexes).count <= deletionLimit else {
                continue
            }
            selectedRanges.append(candidate.range)
            selectedTokenIndexes.formUnion(candidateTokenIndexes)
        }

        let removed = remove(selectedRanges, from: input.transcript)
        let shiftedProtectedSpans = input.protectedSpans.compactMap { span -> CleanupProtectedSpan? in
            guard !selectedRanges.contains(where: { $0.overlaps(span.range) }) else { return nil }
            let removedBefore = selectedRanges
                .filter { $0.upperBound <= span.range.lowerBound }
                .reduce(0) { $0 + $1.length }
            return CleanupProtectedSpan(
                name: span.name,
                text: span.text,
                range: CleanupTextRange(
                    span.range.lowerBound - removedBefore,
                    span.range.upperBound - removedBefore
                )
            )
        }
        return normalizeFormatting(in: removed, preserving: shiftedProtectedSpans)
    }

    func normalizeAccepted(
        _ text: String,
        preserving sourceSpans: [CleanupProtectedSpan]
    ) -> String {
        let sortedSpans = sourceSpans.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound < $1.range.upperBound
        }
        var cursor = text.startIndex
        var generatedSpans: [CleanupProtectedSpan] = []
        for span in sortedSpans {
            guard let range = text.range(
                of: span.text,
                options: [],
                range: cursor..<text.endIndex
            ) else {
                return text
            }
            generatedSpans.append(
                CleanupProtectedSpan(
                    name: span.name,
                    text: span.text,
                    range: CleanupText.byteRange(in: text, for: range)
                )
            )
            cursor = range.upperBound
        }
        return normalizeFormatting(in: text, preserving: generatedSpans)
    }

    private func remove(_ ranges: [CleanupTextRange], from text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for range in ranges {
            guard let stringRange = CleanupText.stringRange(in: text, for: range) else { continue }
            result.append(contentsOf: text[cursor..<stringRange.lowerBound])
            cursor = stringRange.upperBound
        }
        result.append(contentsOf: text[cursor...])
        return result
    }

    private func normalizeFormatting(
        in text: String,
        preserving protectedSpans: [CleanupProtectedSpan]
    ) -> String {
        let protected = protectSpans(in: text, spans: protectedSpans)
        var normalized = protected.text
        normalized = normalized.replacingOccurrences(
            of: #"[ \t]+"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"[ \t]+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"[ \t]*\n[ \t]*"#,
            with: "\n",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        normalized = normalizeCorePunctuation(in: normalized)
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        for entry in protected.entries.reversed() {
            normalized = normalized.replacingOccurrences(of: entry.placeholder, with: entry.text)
        }
        return normalized
    }

    /// Applies only punctuation changes that cannot affect lexical tokens.
    /// A mixed punctuation run left where a deleted token was (for example
    /// `.,`) is removed and its sentence terminator is retained at the end.
    /// This keeps the fallback useful without guessing new words or bullets.
    private func normalizeCorePunctuation(in text: String) -> String {
        let characters = Array(text)
        var normalized: [Character] = []
        var movedSentencePunctuation: Character?
        var index = 0

        while index < characters.count {
            let character = characters[index]
            guard isCorePunctuation(character) else {
                normalized.append(character)
                index += 1
                continue
            }

            let runStart = index
            while index < characters.count, isCorePunctuation(characters[index]) {
                index += 1
            }
            let run = Array(characters[runStart..<index])
            let next = nextNonWhitespace(in: characters, after: index)
            let hasSentencePunctuation = run.contains(where: isSentencePunctuation)
            let hasSoftPunctuation = run.contains(where: isSoftPunctuation)

            if run.count > 1, hasSentencePunctuation,
               (hasSoftPunctuation || run.count > 2),
               next.map(isWordLike) == true {
                movedSentencePunctuation = preferredSentencePunctuation(in: run)
                continue
            }

            if run.count > 1 {
                normalized.append(preferredPunctuation(in: run))
            } else {
                normalized.append(contentsOf: run)
            }
        }

        while let first = normalized.first, first.isWhitespace {
            normalized.removeFirst()
        }
        while let first = normalized.first, isCorePunctuation(first) {
            normalized.removeFirst()
            while let next = normalized.first, next.isWhitespace {
                normalized.removeFirst()
            }
        }

        while let last = normalized.last, isSoftPunctuation(last) {
            normalized.removeLast()
            while let previous = normalized.last, previous.isWhitespace {
                normalized.removeLast()
            }
        }

        if let movedSentencePunctuation,
           !hasSentencePunctuationNearEnd(in: normalized) {
            var insertionIndex = normalized.count
            while insertionIndex > 0, isClosingDelimiter(normalized[insertionIndex - 1]) {
                insertionIndex -= 1
            }
            normalized.insert(movedSentencePunctuation, at: insertionIndex)
        }

        return String(normalized)
    }

    private func isCorePunctuation(_ character: Character) -> Bool {
        ",.;:!?".contains(character)
    }

    private func isSentencePunctuation(_ character: Character) -> Bool {
        ".!?".contains(character)
    }

    private func isSoftPunctuation(_ character: Character) -> Bool {
        ",;:".contains(character)
    }

    private func isClosingDelimiter(_ character: Character) -> Bool {
        ")]}\"'”’".contains(character)
    }

    private func isWordLike(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "\u{E000}"
    }

    private func nextNonWhitespace(
        in characters: [Character],
        after index: Int
    ) -> Character? {
        var cursor = index
        while cursor < characters.count, characters[cursor].isWhitespace {
            cursor += 1
        }
        return cursor < characters.count ? characters[cursor] : nil
    }

    private func preferredSentencePunctuation(in run: [Character]) -> Character {
        run.last(where: isSentencePunctuation) ?? "."
    }

    private func preferredPunctuation(in run: [Character]) -> Character {
        run.last ?? "."
    }

    private func hasSentencePunctuationNearEnd(in characters: [Character]) -> Bool {
        var index = characters.count
        while index > 0 {
            let character = characters[index - 1]
            guard character.isWhitespace || isClosingDelimiter(character) else { break }
            index -= 1
        }
        guard index > 0 else { return false }
        return isSentencePunctuation(characters[index - 1])
    }

    private struct ProtectedPlaceholder {
        let placeholder: String
        let text: String
    }

    private func protectSpans(
        in text: String,
        spans: [CleanupProtectedSpan]
    ) -> (text: String, entries: [ProtectedPlaceholder]) {
        let sorted = spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var protectedText = text
        var entries: [ProtectedPlaceholder] = []

        for (index, span) in sorted.enumerated().reversed() {
            guard let range = CleanupText.stringRange(in: protectedText, for: span.range) else { continue }
            var placeholder = "\u{E000}\(index)\u{E001}"
            while protectedText.contains(placeholder) {
                placeholder.append("\u{E002}")
            }
            protectedText.replaceSubrange(range, with: placeholder)
            entries.append(ProtectedPlaceholder(placeholder: placeholder, text: span.text))
        }
        return (protectedText, entries)
    }
}
