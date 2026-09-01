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

    /// Applies the same precompiled replacement, normalization, and protection
    /// rules used by the cleanup pipeline. Runtime callers reuse the compiled
    /// value owned by `ConfigurationStore`; this helper is for one-off tools
    /// and tests.
    func applyingDeterministicRules(to text: String) -> String {
        guard let compiled = try? compileForCleanup(),
              let result = try? CleanupVocabularyProcessor(
                compiledVocabulary: compiled
              ).process(text)
        else { return text }
        return result.text
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

private extension String {
    var foldingKey: String {
        folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
