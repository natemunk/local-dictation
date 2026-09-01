import Foundation

enum PersonalVocabularyEditorError: Error, Equatable, LocalizedError {
    case emptySpokenForm
    case emptyWrittenForm
    case multilineValue
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .emptySpokenForm:
            "The spoken form cannot be empty."
        case .emptyWrittenForm:
            "The written form cannot be empty."
        case .multilineValue:
            "Vocabulary corrections must each fit on one line."
        case let .unsupportedVersion(version):
            "The personal vocabulary uses unsupported version \(version)."
        }
    }
}

struct PersonalVocabularyCorrectionResult: Equatable, Sendable {
    let spokenForm: String
    let writtenForm: String
    let replacedExisting: Bool
    let fileURL: URL
}

/// Applies only a correction the user explicitly confirms. This editor never
/// reads history on its own and never learns silently.
struct PersonalVocabularyEditor {
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
    func addCorrection(
        spokenForm rawSpokenForm: String,
        writtenForm rawWrittenForm: String
    ) throws -> PersonalVocabularyCorrectionResult {
        let spokenForm = rawSpokenForm.trimmingCharacters(in: .whitespacesAndNewlines)
        let writtenForm = rawWrittenForm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenForm.isEmpty else {
            throw PersonalVocabularyEditorError.emptySpokenForm
        }
        guard !writtenForm.isEmpty else {
            throw PersonalVocabularyEditorError.emptyWrittenForm
        }
        guard !spokenForm.contains(where: \.isNewline),
              !writtenForm.contains(where: \.isNewline)
        else {
            throw PersonalVocabularyEditorError.multilineValue
        }

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
                throw PersonalVocabularyEditorError.unsupportedVersion(version)
            }
        } else {
            file = VocabularyFile(version: 1)
        }

        var replacements = file.replacements ?? [:]
        let existingKey = replacements.keys.first {
            $0.caseInsensitiveCompare(spokenForm) == .orderedSame
        }
        if let existingKey { replacements.removeValue(forKey: existingKey) }
        replacements[spokenForm] = writtenForm
        file.version = 1
        file.replacements = replacements

        let encoded = try TOMLDocumentCodec.encode(file)
        try encoded.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )

        return PersonalVocabularyCorrectionResult(
            spokenForm: spokenForm,
            writtenForm: writtenForm,
            replacedExisting: existingKey != nil,
            fileURL: fileURL
        )
    }
}
