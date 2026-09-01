import Foundation

/// Immutable regular-expression state compiled once for a successful
/// configuration generation and reused by every dictation using that profile.
/// `NSRegularExpression` is immutable after construction; the unchecked
/// conformance records that Foundation guarantee for actor/task handoff.
struct CompiledVocabulary: @unchecked Sendable {
    struct ReplacementRule {
        let definition: CleanupVocabularyReplacement
        let expression: NSRegularExpression
    }

    struct ProtectedRule {
        let definition: CleanupProtectedPattern
        let expression: NSRegularExpression
    }

    struct PrefixNormalizer {
        let definition: VocabularyPattern
        let expression: NSRegularExpression
        let normalizedPrefix: String
    }

    let compilationID: UUID
    let replacements: [ReplacementRule]
    let protectedPatterns: [ProtectedRule]
    let prefixNormalizers: [PrefixNormalizer]

    static let empty = CompiledVocabulary(
        compilationID: UUID(),
        replacements: [],
        protectedPatterns: [],
        prefixNormalizers: []
    )

    init(
        replacements: [CleanupVocabularyReplacement],
        protectedPatterns: [CleanupProtectedPattern],
        vocabularyPatterns: [VocabularyPattern] = []
    ) throws {
        var compiledReplacements: [ReplacementRule] = []
        compiledReplacements.reserveCapacity(replacements.count)
        for (index, replacement) in replacements.enumerated() {
            let words = replacement.spokenForm.split(whereSeparator: \Character.isWhitespace)
            guard !words.isEmpty else {
                throw CleanupVocabularyError.emptySpokenForm(index: index)
            }
            let escaped = words
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"[ \t]+"#)
            let pattern = #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
            let options: NSRegularExpression.Options = replacement.isCaseSensitive
                ? []
                : [.caseInsensitive]
            do {
                compiledReplacements.append(
                    ReplacementRule(
                        definition: replacement,
                        expression: try NSRegularExpression(pattern: pattern, options: options)
                    )
                )
            } catch {
                throw CleanupVocabularyError.invalidReplacementPattern(
                    index: index,
                    expression: pattern
                )
            }
        }

        var compiledProtectedPatterns: [ProtectedRule] = []
        compiledProtectedPatterns.reserveCapacity(protectedPatterns.count)
        for pattern in protectedPatterns {
            let options: NSRegularExpression.Options = pattern.isCaseInsensitive
                ? [.caseInsensitive]
                : []
            do {
                compiledProtectedPatterns.append(
                    ProtectedRule(
                        definition: pattern,
                        expression: try NSRegularExpression(
                            pattern: pattern.expression,
                            options: options
                        )
                    )
                )
            } catch {
                throw CleanupVocabularyError.invalidProtectedPattern(
                    name: pattern.name,
                    expression: pattern.expression
                )
            }
        }

        let orderedPatterns = vocabularyPatterns.sorted { lhs, rhs in
            if lhs.prefix.count != rhs.prefix.count {
                return lhs.prefix.count > rhs.prefix.count
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        var normalizers: [PrefixNormalizer] = []
        normalizers.reserveCapacity(orderedPatterns.count)
        for pattern in orderedPatterns {
            switch pattern.kind {
            case .prefixedDigits:
                let expressionText = #"(?<![\p{L}\p{N}_])"#
                    + NSRegularExpression.escapedPattern(for: pattern.prefix)
                    + #"([0-9]+)(?![\p{L}\p{N}_])"#
                let normalizedPrefix: String
                switch pattern.outputCase {
                case .uppercase:
                    normalizedPrefix = pattern.prefix.uppercased()
                case .lowercase:
                    normalizedPrefix = pattern.prefix.lowercased()
                case .preserve:
                    normalizedPrefix = pattern.prefix
                }
                do {
                    normalizers.append(
                        PrefixNormalizer(
                            definition: pattern,
                            expression: try NSRegularExpression(
                                pattern: expressionText,
                                options: [.caseInsensitive]
                            ),
                            normalizedPrefix: normalizedPrefix
                        )
                    )
                } catch {
                    throw CleanupVocabularyError.invalidTypedPattern(
                        name: pattern.name,
                        expression: expressionText
                    )
                }
            }
        }

        self.init(
            compilationID: UUID(),
            replacements: compiledReplacements,
            protectedPatterns: compiledProtectedPatterns,
            prefixNormalizers: normalizers
        )
    }

    private init(
        compilationID: UUID,
        replacements: [ReplacementRule],
        protectedPatterns: [ProtectedRule],
        prefixNormalizers: [PrefixNormalizer]
    ) {
        self.compilationID = compilationID
        self.replacements = replacements
        self.protectedPatterns = protectedPatterns
        self.prefixNormalizers = prefixNormalizers
    }

    func normalizeTypedPatterns(in text: String) -> String {
        var output = text
        for normalizer in prefixNormalizers {
            let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
            let matches = normalizer.expression.matches(in: output, range: fullRange)
            for match in matches.reversed() {
                guard let matchRange = Range(match.range(at: 0), in: output),
                      let digitsRange = Range(match.range(at: 1), in: output)
                else { continue }
                let digits = String(output[digitsRange])
                output.replaceSubrange(
                    matchRange,
                    with: normalizer.normalizedPrefix + digits
                )
            }
        }
        return output
    }
}

extension VocabularyPack {
    func compileForCleanup() throws -> CompiledVocabulary {
        var definitions: [CleanupVocabularyReplacement] = []
        var seen = Set<String>()

        func append(
            spokenForm: String,
            writtenForm: String,
            isProtected: Bool = true
        ) {
            let key = spokenForm.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(key).inserted else { return }
            definitions.append(
                CleanupVocabularyReplacement(
                    spokenForm: spokenForm,
                    writtenForm: writtenForm,
                    isProtected: isProtected
                )
            )
        }

        for (source, replacement) in replacements.sorted(by: { lhs, rhs in
            if lhs.key.count != rhs.key.count { return lhs.key.count > rhs.key.count }
            return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
        }) {
            append(spokenForm: source, writtenForm: replacement)
        }
        for phrase in literalPhrases.sorted(by: Self.longestFirst) {
            append(spokenForm: phrase, writtenForm: phrase)
        }
        for term in protectedTerms.sorted(by: Self.longestFirst) {
            append(spokenForm: term, writtenForm: term)
        }

        let configuredPatterns = patterns.map { pattern in
            CleanupProtectedPattern(
                name: pattern.name,
                expression: #"(?<![\p{L}\p{N}_])"#
                    + NSRegularExpression.escapedPattern(for: pattern.prefix)
                    + #"[0-9]+(?![\p{L}\p{N}_])"#,
                isCaseInsensitive: true
            )
        }
        return try CompiledVocabulary(
            replacements: definitions,
            protectedPatterns: CleanupProtectedPattern.standard + configuredPatterns,
            vocabularyPatterns: patterns
        )
    }

    private static func longestFirst(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
}
