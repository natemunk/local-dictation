import Foundation

enum VocabularyPatternKind: String, Codable, CaseIterable, Sendable {
    case prefixedDigits = "prefixed_digits"
}

enum VocabularyPatternCase: String, Codable, CaseIterable, Sendable {
    case uppercase
    case lowercase
    case preserve
}

struct VocabularyPattern: Codable, Equatable, Sendable {
    var name: String
    var kind: VocabularyPatternKind
    var prefix: String
    var outputCase: VocabularyPatternCase

    init(
        name: String,
        kind: VocabularyPatternKind,
        prefix: String,
        outputCase: VocabularyPatternCase
    ) {
        self.name = name
        self.kind = kind
        self.prefix = prefix
        self.outputCase = outputCase
    }

    enum CodingKeys: String, CodingKey {
        case name
        case kind
        case prefix
        case outputCase = "output_case"
    }
}

struct VocabularyPack: Equatable, Sendable {
    let id: String
    var literalPhrases: [String]
    var replacements: [String: String]
    var protectedTerms: [String]
    var patterns: [VocabularyPattern]

    init(
        id: String,
        literalPhrases: [String] = [],
        replacements: [String: String] = [:],
        protectedTerms: [String] = [],
        patterns: [VocabularyPattern] = []
    ) {
        self.id = id
        self.literalPhrases = literalPhrases
        self.replacements = replacements
        self.protectedTerms = protectedTerms
        self.patterns = patterns
    }

    /// Applies configured replacements and typed patterns in a stable order.
    /// Literal phrases and protected terms are exposed as metadata for the ASR
    /// and cleanup layers; they do not mutate text by themselves.
    func applyingDeterministicRules(to text: String) -> String {
        var result = text

        let orderedReplacements = replacements.sorted { lhs, rhs in
            if lhs.key.count != rhs.key.count { return lhs.key.count > rhs.key.count }
            let foldedComparison = lhs.key.lowercased().compare(rhs.key.lowercased())
            if foldedComparison != .orderedSame { return foldedComparison == .orderedAscending }
            return lhs.key < rhs.key
        }

        for (source, replacement) in orderedReplacements {
            result = Self.replacingPhrase(
                source,
                with: replacement,
                in: result
            )
        }

        let orderedPatterns = patterns.sorted { lhs, rhs in
            if lhs.prefix.count != rhs.prefix.count { return lhs.prefix.count > rhs.prefix.count }
            return lhs.name < rhs.name
        }
        for pattern in orderedPatterns {
            result = pattern.applying(to: result)
        }

        return result
    }

    func combining(_ laterPack: VocabularyPack) -> VocabularyPack {
        var combined = self
        combined.literalPhrases = Self.appendingUnique(
            laterPack.literalPhrases,
            to: combined.literalPhrases
        )
        combined.protectedTerms = Self.appendingUnique(
            laterPack.protectedTerms,
            to: combined.protectedTerms
        )

        for (source, replacement) in laterPack.replacements {
            if let existing = combined.replacements.keys.first(where: {
                $0.caseInsensitiveCompare(source) == .orderedSame
            }) {
                combined.replacements.removeValue(forKey: existing)
            }
            combined.replacements[source] = replacement
        }

        for pattern in laterPack.patterns {
            combined.patterns.removeAll {
                $0.name.caseInsensitiveCompare(pattern.name) == .orderedSame
            }
            combined.patterns.append(pattern)
        }
        return combined
    }

    private static func replacingPhrase(
        _ source: String,
        with replacement: String,
        in text: String
    ) -> String {
        guard !source.isEmpty else { return text }
        let startsWithWordCharacter = source.first.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
        let endsWithWordCharacter = source.last.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
        let leadingBoundary = startsWithWordCharacter ? "(?<![\\p{L}\\p{N}_])" : ""
        let trailingBoundary = endsWithWordCharacter ? "(?![\\p{L}\\p{N}_])" : ""
        let pattern = leadingBoundary
            + NSRegularExpression.escapedPattern(for: source)
            + trailingBoundary

        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    private static func appendingUnique(_ values: [String], to existing: [String]) -> [String] {
        var result = existing
        var seen = Set(existing.map { $0.foldingKey })
        for value in values where seen.insert(value.foldingKey).inserted {
            result.append(value)
        }
        return result
    }
}

struct VocabularyCatalog: Equatable, Sendable {
    var global: VocabularyPack
    var packs: [String: VocabularyPack]

    init(global: VocabularyPack, packs: [String: VocabularyPack]) {
        self.global = global
        self.packs = packs
    }

    func selection(including packIDs: [String]) -> VocabularyPack {
        var selection = VocabularyPack(
            id: "selection",
            literalPhrases: global.literalPhrases,
            replacements: global.replacements,
            protectedTerms: global.protectedTerms,
            patterns: global.patterns
        )
        // Personal corrections are global user intent, not profile-specific
        // behavior. Apply them last so an explicit personal correction wins
        // over bundled or profile packs immediately after reload/import.
        let orderedPackIDs = packIDs.filter {
            $0.caseInsensitiveCompare("personal") != .orderedSame
        } + (packs["personal"] == nil ? [] : ["personal"])
        var seen = Set<String>()
        for id in orderedPackIDs where seen.insert(id.lowercased()).inserted {
            if let pack = packs[id] {
                selection = selection.combining(pack)
            }
        }
        return selection
    }

    static let nativeDefaults = VocabularyCatalog(
        global: VocabularyPack(
            id: "global",
            literalPhrases: ["Local Dictation"],
            protectedTerms: ["Local Dictation"]
        ),
        packs: [
            "symphony": VocabularyPack(
                id: "symphony",
                literalPhrases: [
                    "Symphony",
                    "MyEducator",
                    "Voshi",
                    "LearnWise",
                    "Qwen",
                    "OpenRouter",
                    "AI Dialogue",
                    "coursenum",
                ],
                replacements: [
                    "my educator": "MyEducator",
                    "learn wise": "LearnWise",
                    "open router": "OpenRouter",
                    "course num": "coursenum",
                ],
                protectedTerms: [
                    "Symphony",
                    "MyEducator",
                    "Voshi",
                    "LearnWise",
                    "Qwen",
                    "OpenRouter",
                    "AI Dialogue",
                    "coursenum",
                ],
                patterns: [
                    VocabularyPattern(
                        name: "mye_ticket",
                        kind: .prefixedDigits,
                        prefix: "MYE-",
                        outputCase: .uppercase
                    ),
                ]
            ),
        ]
    )
}

struct VocabularyFile: Codable, Equatable {
    var version: Int?
    var literalPhrases: [String]?
    var replacements: [String: String]?
    var protectedTerms: [String]?
    var patterns: [VocabularyPattern]?

    init(
        version: Int? = nil,
        literalPhrases: [String]? = nil,
        replacements: [String: String]? = nil,
        protectedTerms: [String]? = nil,
        patterns: [VocabularyPattern]? = nil
    ) {
        self.version = version
        self.literalPhrases = literalPhrases
        self.replacements = replacements
        self.protectedTerms = protectedTerms
        self.patterns = patterns
    }

    enum CodingKeys: String, CodingKey {
        case version
        case literalPhrases = "literal_phrases"
        case replacements
        case protectedTerms = "protected_terms"
        case patterns
    }
}

extension VocabularyPack {
    func applying(_ file: VocabularyFile) -> VocabularyPack {
        var merged = self
        if let value = file.literalPhrases { merged.literalPhrases = value }
        if let value = file.protectedTerms { merged.protectedTerms = value }
        if let value = file.patterns { merged.patterns = value }
        if let values = file.replacements {
            for (source, replacement) in values {
                if let existing = merged.replacements.keys.first(where: {
                    $0.caseInsensitiveCompare(source) == .orderedSame
                }) {
                    merged.replacements.removeValue(forKey: existing)
                }
                merged.replacements[source] = replacement
            }
        }
        return merged
    }
}

private extension VocabularyPattern {
    func applying(to text: String) -> String {
        switch kind {
        case .prefixedDigits:
            return applyingPrefixedDigits(to: text)
        }
    }

    func applyingPrefixedDigits(to text: String) -> String {
        let expressionPattern = "(?<![\\p{L}\\p{N}_])"
            + NSRegularExpression.escapedPattern(for: prefix)
            + "([0-9]+)(?![\\p{L}\\p{N}_])"
        guard let expression = try? NSRegularExpression(
            pattern: expressionPattern,
            options: [.caseInsensitive]
        ) else {
            return text
        }

        let normalizedPrefix: String
        switch outputCase {
        case .uppercase:
            normalizedPrefix = prefix.uppercased()
        case .lowercase:
            normalizedPrefix = prefix.lowercased()
        case .preserve:
            normalizedPrefix = prefix
        }

        var output = text
        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        let matches = expression.matches(in: output, range: fullRange)
        for match in matches.reversed() {
            guard let matchRange = Range(match.range(at: 0), in: output),
                  let digitsRange = Range(match.range(at: 1), in: output)
            else {
                continue
            }
            let digits = output[digitsRange]
            output.replaceSubrange(matchRange, with: normalizedPrefix + digits)
        }
        return output
    }
}

private extension String {
    var foldingKey: String {
        folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
