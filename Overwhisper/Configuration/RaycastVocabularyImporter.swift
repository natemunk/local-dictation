import Foundation

enum RaycastVocabularyImportError: Error, Equatable {
    case malformedQuotedPhrase
    case noPhrases
    case unsupportedVersion(Int)
}

struct RaycastVocabularyImportResult: Equatable, Sendable {
    let importedCount: Int
    let totalCount: Int
    let fileURL: URL
}

/// Imports text the user explicitly copied from Raycast. This type has no API
/// for discovering or reading Raycast's files, preferences, or databases.
struct RaycastVocabularyImporter {
    let paths: ConfigurationPaths
    private let fileManager: FileManager

    init(
        paths: ConfigurationPaths = .userDefault,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
    }

    @discardableResult
    func importCommaSeparated(_ input: String) throws -> RaycastVocabularyImportResult {
        let imported = try Self.parse(input)
        guard !imported.isEmpty else { throw RaycastVocabularyImportError.noPhrases }

        try fileManager.createDirectory(
            at: paths.vocabularyPacksDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let fileURL = paths.personalVocabularyFile
        var file: VocabularyFile
        if fileManager.fileExists(atPath: fileURL.path) {
            file = try TOMLDocumentCodec.decode(VocabularyFile.self, from: fileURL)
            if let version = file.version, version != 1 {
                throw RaycastVocabularyImportError.unsupportedVersion(version)
            }
        } else {
            file = VocabularyFile(version: 1)
        }

        let existing = file.literalPhrases ?? []
        var merged = existing
        var seen = Set(existing.map(Self.foldingKey))
        var addedCount = 0
        for phrase in imported where seen.insert(Self.foldingKey(phrase)).inserted {
            merged.append(phrase)
            addedCount += 1
        }

        file.version = 1
        file.literalPhrases = merged
        let data = try TOMLDocumentCodec.encode(file)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        return RaycastVocabularyImportResult(
            importedCount: addedCount,
            totalCount: merged.count,
            fileURL: fileURL
        )
    }

    static func parse(_ input: String) throws -> [String] {
        var fields: [String] = []
        var field = ""
        var insideQuotes = false
        var index = input.startIndex

        func finishField() {
            let phrase = field.trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty { fields.append(phrase) }
            field = ""
        }

        while index < input.endIndex {
            let character = input[index]
            if character == "\"" {
                let next = input.index(after: index)
                if insideQuotes, next < input.endIndex, input[next] == "\"" {
                    field.append("\"")
                    index = input.index(after: next)
                    continue
                }
                insideQuotes.toggle()
            } else if !insideQuotes, character == "," || character == "\n" || character == "\r" {
                finishField()
            } else {
                field.append(character)
            }
            index = input.index(after: index)
        }

        guard !insideQuotes else { throw RaycastVocabularyImportError.malformedQuotedPhrase }
        finishField()

        var unique: [String] = []
        var seen = Set<String>()
        for field in fields where seen.insert(foldingKey(field)).inserted {
            unique.append(field)
        }
        return unique
    }

    private static func foldingKey(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
