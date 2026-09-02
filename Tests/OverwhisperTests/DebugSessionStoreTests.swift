import Foundation
import Testing
@testable import LocalDictation

@Suite("Debug session retention")
@MainActor
struct DebugSessionStoreTests {
    @Test("clear removes transcript metadata and orphaned files")
    func clearRemovesWholeDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-debug-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DebugSessionStore(rootDirectory: root)
        _ = store.record(
            engine: "test",
            model: "fixture",
            sourceAudioURL: nil,
            recordingDuration: 1,
            transcribedText: "uniquely sensitive debug transcript",
            latencySeconds: 0.1,
            language: "en",
            errorMessage: nil
        )
        let orphan = store.audioDirectory.appendingPathComponent("orphan.wav")
        try Data("orphan audio".utf8).write(to: orphan)

        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(store.sessions.count == 1)
        #expect(store.clear())
        #expect(store.sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
