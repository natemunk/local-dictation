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
            of: #"([,;:])[ \t]*\1"#,
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
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        for entry in protected.entries.reversed() {
            normalized = normalized.replacingOccurrences(of: entry.placeholder, with: entry.text)
        }
        return normalized
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
