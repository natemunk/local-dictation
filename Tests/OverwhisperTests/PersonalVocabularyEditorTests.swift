import Foundation
import Testing
@testable import LocalDictation

@Suite("Personal vocabulary editor")
struct PersonalVocabularyEditorTests {
    @Test("an explicit correction transactionally preserves the personal pack")
    func addsAndReplacesCorrection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalVocabularyEditorTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConfigurationPaths(rootDirectory: root)
        try FileManager.default.createDirectory(
            at: paths.vocabularyPacksDirectory,
            withIntermediateDirectories: true
        )
        let initial = VocabularyFile(
            version: 1,
            literalPhrases: ["Nate"],
            replacements: ["open router": "OpenRouter"],
            protectedTerms: ["Nate"]
        )
        try TOMLDocumentCodec.encode(initial).write(
            to: paths.personalVocabularyFile,
            options: [.atomic]
        )

        let editor = PersonalVocabularyEditor(paths: paths)
        let added = try editor.addCorrection(
            spokenForm: "my educator",
            writtenForm: "MyEducator"
        )
        #expect(!added.replacedExisting)

        let replaced = try editor.addCorrection(
            spokenForm: "OPEN ROUTER",
            writtenForm: "OpenRouter AI"
        )
        #expect(replaced.replacedExisting)

        let saved = try TOMLDocumentCodec.decode(
            VocabularyFile.self,
            from: paths.personalVocabularyFile
        )
        #expect(saved.literalPhrases == ["Nate"])
        #expect(saved.protectedTerms == ["Nate"])
        #expect(saved.replacements?["my educator"] == "MyEducator")
        #expect(saved.replacements?["OPEN ROUTER"] == "OpenRouter AI")
        #expect(saved.replacements?["open router"] == nil)

        let permissions = try FileManager.default.attributesOfItem(
            atPath: paths.personalVocabularyFile.path
        )[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("invalid input or malformed existing TOML never replaces the file")
    func failurePreservesExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalVocabularyEditorTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ConfigurationPaths(rootDirectory: root)
        try FileManager.default.createDirectory(
            at: paths.vocabularyPacksDirectory,
            withIntermediateDirectories: true
        )
        let malformed = Data("version = [\n".utf8)
        try malformed.write(to: paths.personalVocabularyFile)

        #expect(throws: ConfigurationDocumentError.self) {
            try PersonalVocabularyEditor(paths: paths).addCorrection(
                spokenForm: "my educator",
                writtenForm: "MyEducator"
            )
        }
        #expect(try Data(contentsOf: paths.personalVocabularyFile) == malformed)

        try FileManager.default.removeItem(at: paths.personalVocabularyFile)
        #expect(throws: PersonalVocabularyEditorError.emptySpokenForm) {
            try PersonalVocabularyEditor(paths: paths).addCorrection(
                spokenForm: "   ",
                writtenForm: "MyEducator"
            )
        }
        #expect(!FileManager.default.fileExists(atPath: paths.personalVocabularyFile.path))
    }
}
