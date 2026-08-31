import Foundation
import Testing
@testable import LocalDictation

@Suite("Raycast vocabulary importer")
struct ConfigurationImporterTests {
    @Test("pasted comma-separated vocabulary becomes an idempotent personal pack")
    func importsPersonalPack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = ConfigurationPaths(rootDirectory: root)
        let importer = RaycastVocabularyImporter(paths: paths)

        let first = try importer.importCommaSeparated(
            "Symphony, Voshi, symphony, \"AI, Dialogue\", Qwen\nOpenRouter"
        )
        #expect(first.importedCount == 5)
        #expect(first.totalCount == 5)
        #expect(first.fileURL == paths.personalVocabularyFile)

        let second = try importer.importCommaSeparated("LearnWise, voshi")
        #expect(second.importedCount == 1)
        #expect(second.totalCount == 6)

        let file = try TOMLDocumentCodec.decode(VocabularyFile.self, from: paths.personalVocabularyFile)
        #expect(
            file.literalPhrases == [
                "Symphony",
                "Voshi",
                "AI, Dialogue",
                "Qwen",
                "OpenRouter",
                "LearnWise",
            ]
        )

        let store = ConfigurationStore(paths: paths)
        let loaded = store.bootstrapAndReload()
        #expect(loaded.applied)
        #expect(
            loaded.snapshot.vocabulary.packs["personal"]?.literalPhrases
                == file.literalPhrases
        )
    }

    @Test("malformed pasted input cannot replace an existing personal pack")
    func malformedInputPreservesFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = ConfigurationPaths(rootDirectory: root)
        let importer = RaycastVocabularyImporter(paths: paths)
        _ = try importer.importCommaSeparated("Symphony, Voshi")
        let before = try Data(contentsOf: paths.personalVocabularyFile)

        #expect(throws: RaycastVocabularyImportError.malformedQuotedPhrase) {
            try importer.importCommaSeparated("\"unfinished, phrase")
        }
        #expect(try Data(contentsOf: paths.personalVocabularyFile) == before)
    }
}
