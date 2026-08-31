import Foundation

struct WERMeasurement: Sendable {
    let referenceTokens: [String]
    let hypothesisTokens: [String]
    let edits: EditCounts
    let weightedErrors: Int
    let weightedReferenceWords: Int

    var standardWER: Double {
        Double(edits.total) / Double(referenceTokens.count)
    }

    var domainWeightedWER: Double {
        Double(weightedErrors) / Double(weightedReferenceWords)
    }
}

enum WERScorer {
    private static let wordPattern = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:['’_-][\p{L}\p{N}]+)*"#
    )
    private static let ticketPattern = try! NSRegularExpression(
        pattern: #"^[a-z][a-z0-9]*-[0-9]+$"#
    )

    static func tokenize(_ text: String) -> [String] {
        let canonical = text.precomposedStringWithCanonicalMapping
        let range = NSRange(canonical.startIndex..<canonical.endIndex, in: canonical)
        return wordPattern.matches(in: canonical, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: canonical) else { return nil }
            return canonical[tokenRange]
                .replacingOccurrences(of: "’", with: "'")
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
        }
    }

    static func measure(
        reference: String,
        hypothesis: String,
        protectedTokens: [String]
    ) -> WERMeasurement {
        let referenceWords = tokenize(reference)
        let hypothesisWords = tokenize(hypothesis)
        let protectedPhrases = protectedTokens.map(tokenize).filter { !$0.isEmpty }
        let protectedWordSet = Set(protectedPhrases.flatMap { $0 })

        let referenceProtected = protectedIndices(
            words: referenceWords,
            phrases: protectedPhrases
        )
        let referenceWeights = referenceWords.enumerated().map { index, word in
            referenceProtected.contains(index) || isTicket(word)
                ? BenchmarkConstants.protectedTokenWeight
                : 1
        }
        let hypothesisWeights = hypothesisWords.map { word in
            protectedWordSet.contains(word) || isTicket(word)
                ? BenchmarkConstants.protectedTokenWeight
                : 1
        }

        return WERMeasurement(
            referenceTokens: referenceWords,
            hypothesisTokens: hypothesisWords,
            edits: standardDistance(reference: referenceWords, hypothesis: hypothesisWords),
            weightedErrors: weightedDistance(
                reference: referenceWords,
                hypothesis: hypothesisWords,
                referenceWeights: referenceWeights,
                hypothesisWeights: hypothesisWeights
            ),
            weightedReferenceWords: referenceWeights.reduce(0, +)
        )
    }

    static func protectedTokensAppearInReference(
        reference: String,
        protectedTokens: [String]
    ) -> [String] {
        let referenceWords = tokenize(reference)
        return protectedTokens.filter { token in
            let phrase = tokenize(token)
            return phrase.isEmpty || !contains(phrase: phrase, in: referenceWords)
        }
    }

    private static func protectedIndices(words: [String], phrases: [[String]]) -> Set<Int> {
        var indices = Set<Int>()
        for phrase in phrases where phrase.count <= words.count {
            guard !phrase.isEmpty else { continue }
            for start in 0...(words.count - phrase.count) {
                if Array(words[start..<(start + phrase.count)]) == phrase {
                    indices.formUnion(start..<(start + phrase.count))
                }
            }
        }
        return indices
    }

    private static func contains(phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= words.count else { return false }
        for start in 0...(words.count - phrase.count) {
            if Array(words[start..<(start + phrase.count)]) == phrase {
                return true
            }
        }
        return false
    }

    private static func isTicket(_ word: String) -> Bool {
        let range = NSRange(word.startIndex..<word.endIndex, in: word)
        return ticketPattern.firstMatch(in: word, range: range) != nil
    }

    private static func standardDistance(
        reference: [String],
        hypothesis: [String]
    ) -> EditCounts {
        struct Cell {
            var cost: Int
            var edits: EditCounts
        }

        func preferred(_ lhs: Cell, _ rhs: Cell) -> Cell {
            let leftKey = [
                lhs.cost,
                lhs.edits.substitutions,
                lhs.edits.deletions,
                lhs.edits.insertions,
            ]
            let rightKey = [
                rhs.cost,
                rhs.edits.substitutions,
                rhs.edits.deletions,
                rhs.edits.insertions,
            ]
            return leftKey.lexicographicallyPrecedes(rightKey) ? lhs : rhs
        }

        var previous = (0...hypothesis.count).map { count in
            Cell(
                cost: count,
                edits: EditCounts(substitutions: 0, deletions: 0, insertions: count)
            )
        }

        for referenceIndex in reference.indices {
            var current = Array(
                repeating: Cell(
                    cost: 0,
                    edits: EditCounts(substitutions: 0, deletions: 0, insertions: 0)
                ),
                count: hypothesis.count + 1
            )
            current[0] = Cell(
                cost: referenceIndex + 1,
                edits: EditCounts(substitutions: 0, deletions: referenceIndex + 1, insertions: 0)
            )

            guard !hypothesis.isEmpty else {
                previous = current
                continue
            }
            for hypothesisOffset in 1...hypothesis.count {
                let hypothesisIndex = hypothesisOffset - 1
                if reference[referenceIndex] == hypothesis[hypothesisIndex] {
                    current[hypothesisOffset] = previous[hypothesisOffset - 1]
                    continue
                }

                var substitution = previous[hypothesisOffset - 1]
                substitution.cost += 1
                substitution.edits.substitutions += 1

                var deletion = previous[hypothesisOffset]
                deletion.cost += 1
                deletion.edits.deletions += 1

                var insertion = current[hypothesisOffset - 1]
                insertion.cost += 1
                insertion.edits.insertions += 1

                current[hypothesisOffset] = preferred(
                    substitution,
                    preferred(deletion, insertion)
                )
            }
            previous = current
        }

        return previous[hypothesis.count].edits
    }

    private static func weightedDistance(
        reference: [String],
        hypothesis: [String],
        referenceWeights: [Int],
        hypothesisWeights: [Int]
    ) -> Int {
        var previous = Array(repeating: 0, count: hypothesis.count + 1)
        for index in hypothesis.indices {
            previous[index + 1] = previous[index] + hypothesisWeights[index]
        }

        for referenceIndex in reference.indices {
            var current = Array(repeating: 0, count: hypothesis.count + 1)
            current[0] = previous[0] + referenceWeights[referenceIndex]
            guard !hypothesis.isEmpty else {
                previous = current
                continue
            }
            for hypothesisOffset in 1...hypothesis.count {
                let hypothesisIndex = hypothesisOffset - 1
                if reference[referenceIndex] == hypothesis[hypothesisIndex] {
                    current[hypothesisOffset] = previous[hypothesisOffset - 1]
                    continue
                }

                let substitution = previous[hypothesisOffset - 1]
                    + max(referenceWeights[referenceIndex], hypothesisWeights[hypothesisIndex])
                let deletion = previous[hypothesisOffset] + referenceWeights[referenceIndex]
                let insertion = current[hypothesisOffset - 1] + hypothesisWeights[hypothesisIndex]
                current[hypothesisOffset] = min(substitution, deletion, insertion)
            }
            previous = current
        }

        return previous[hypothesis.count]
    }
}
