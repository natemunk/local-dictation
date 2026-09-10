import AppKit
import Foundation
import Testing
@testable import LocalDictation

@Suite("Mac recovery regressions", .serialized)
struct MacRecoveryRegressionTests {
    @Test("stale Mac edits keep both versions and cannot overwrite phone edits")
    @MainActor
    func staleEditPreservesDraft() async throws {
        let store = try HistoryStore.inMemory()
        let original = try await store.saveRaw(HistoryRawCapture(rawText: "Original fixture", mode: .clean))
        let model = makeHistoryModel(store)
        model.entries = [original]
        model.selection = original.id
        model.beginEditing()
        model.editDraft = "Mac draft fixture"
        _ = try await store.setUserEditedText(id: original.id, text: "Phone edit fixture", baseRevision: original.entryRevision)

        model.saveEdit()
        try await waitUntil { !model.isSavingEdit }
        #expect(model.isEditing)
        #expect(model.editDraft == "Mac draft fixture")
        #expect(model.selectedTextForDelivery == "Mac draft fixture")
        #expect(model.conflictingText == "Phone edit fixture")
        #expect(model.errorMessage != nil)
        #expect(try await store.fetch(id: original.id)?.displayText == "Phone edit fixture")

        model.cancelEditing()
        model.beginEditing()
        #expect(model.editDraft == "Phone edit fixture")
        model.editDraft = "Reviewed fixture"
        model.saveEdit()
        try await waitUntil { !model.isSavingEdit }
        #expect(!model.isEditing)
        #expect(try await store.fetch(id: original.id)?.displayText == "Reviewed fixture")
    }

    @Test("an old asynchronous Save cannot close a new editor")
    @MainActor
    func saveCompletionOwnsItsDraft() async throws {
        let store = try HistoryStore.inMemory()
        let first = try await store.saveRaw(HistoryRawCapture(rawText: "First fixture", mode: .clean))
        let second = try await store.saveRaw(HistoryRawCapture(rawText: "Second fixture", mode: .clean))
        let gate = EditGate()
        let model = makeHistoryModel(store, writeEdit: { id, text, revision in
            await gate.wait()
            return try await store.setUserEditedText(id: id, text: text, baseRevision: revision)
        })
        model.entries = [first, second]
        model.selection = first.id
        model.beginEditing()
        model.editDraft = "First edited fixture"
        model.saveEdit()
        model.selection = second.id
        model.beginEditing()
        model.editDraft = "Second unsaved fixture"
        await gate.open()
        try await waitUntil { !model.isSavingEdit }
        #expect(model.selection == second.id)
        #expect(model.isEditing)
        #expect(model.editDraft == "Second unsaved fixture")
        #expect(try await store.fetch(id: first.id)?.displayText == "First edited fixture")
        #expect(try await store.fetch(id: second.id)?.displayText == "Second fixture")
    }

    @Test("typing after Save is preserved and the next save uses the new revision")
    @MainActor
    func typingDuringSavePreservesNewerWords() async throws {
        let store = try HistoryStore.inMemory()
        let entry = try await store.saveRaw(HistoryRawCapture(rawText: "Initial fixture", mode: .clean))
        let gate = EditGate()
        let model = makeHistoryModel(store, writeEdit: { id, text, revision in
            await gate.wait()
            return try await store.setUserEditedText(id: id, text: text, baseRevision: revision)
        })
        model.entries = [entry]
        model.selection = entry.id
        model.beginEditing()
        model.editDraft = "Submitted fixture"
        model.saveEdit()
        model.editDraft = "Newer words fixture"
        await gate.open()
        try await waitUntil { !model.isSavingEdit }
        #expect(model.isEditing)
        #expect(model.editDraft == "Newer words fixture")
        #expect(try await store.fetch(id: entry.id)?.displayText == "Submitted fixture")
        model.saveEdit()
        try await waitUntil { !model.isSavingEdit }
        #expect(!model.isEditing)
        #expect(try await store.fetch(id: entry.id)?.displayText == "Newer words fixture")
    }

    @Test("failed insertion may recover to an editable preview without starting a new session")
    @MainActor
    func pasteFailureCanRecoverToPreview() throws {
        let coordinator = DictationCoordinator()
        _ = coordinator.hotkeyDown(at: 0, profileMode: .clean)
        let token = try #require(coordinator.session?.token)
        _ = coordinator.finishFromMenu()
        #expect(coordinator.transition(token: token, to: .pasting))
        #expect(coordinator.transition(token: token, to: .previewing))
        #expect(coordinator.session?.token == token)
        #expect(!coordinator.enterPressed(modifiers: [], profileMode: .clean).consumeKeyEvent)
    }

    @Test("failed preview Copy retains the same editor and exposes retry without clipboard IO")
    @MainActor
    func previewCopyFailure() throws {
        let token = DictationSessionToken(generation: 1, id: UUID())
        let controller = PreviewWindowController(
            onDeliver: { _, _ in Issue.record("Unexpected delivery") },
            onCopy: { _, _ in },
            onCancel: { _ in Issue.record("Unexpected cancellation") },
            presentWindow: { _ in }
        )
        controller.show(text: "Synthetic draft", rawText: "Synthetic raw", isRemoteRefiner: false, token: token)
        defer { controller.close() }
        let editor = try #require(controller.window)
        #expect(!controller.attemptCopy("Edited fixture", token: token, using: { _ in false }))
        #expect(controller.window === editor)
        #expect(controller.notice.message != nil)
        var copied: String?
        #expect(controller.attemptCopy("Edited fixture", token: token, using: { copied = $0; return true }))
        #expect(copied == "Edited fixture")
        #expect(controller.notice.message == nil)
        let stale = DictationSessionToken(generation: 0, id: UUID())
        #expect(!controller.attemptCopy("Stale fixture", token: stale, using: { _ in Issue.record("Stale copy"); return true }))
    }

    @Test("history authorization is rechecked at saving and revocation invalidates older requests")
    func consentAtPersistence() async throws {
        let store = try HistoryStore.inMemory()
        let consent = HistoryPersistenceConsent()
        #expect(consent.authorization() == nil)
        consent.setEnabled(true)
        let oldAuthorization = try #require(consent.authorization())
        let capture = HistoryRemoteCapture(
            id: UUID(), rawText: "Synthetic remote text", polishedText: nil, mode: .literal,
            sourceKind: .iphonePWA, remoteRoute: "mac_local", cleanupBackend: "none", refinementStatus: .notRequested
        )
        consent.setEnabled(false)
        #expect(try await store.saveRemote(capture, authorization: oldAuthorization) == nil)
        #expect(try await store.fetch(id: capture.id) == nil)
        consent.setEnabled(true)
        #expect(try await store.saveRemote(capture, authorization: oldAuthorization) == nil)
        let currentAuthorization = try #require(consent.authorization())
        let saved = try await store.saveRemote(capture, authorization: currentAuthorization)
        #expect(saved?.inserted == true)
        #expect(try await store.fetch(id: capture.id)?.rawText == "Synthetic remote text")
    }

    @Test("long Whisper dictations keep their engine deadline and timeout recovery prefers final raw text")
    func finalizationRecoveryPolicy() throws {
        let engineBudget = ASRDeadlinePolicy.whisperTimeoutSeconds(audioDuration: 900)
        #expect(DictationFinalizationDeadline.seconds(selection: .whisperLargeV3Turbo, audioDuration: 900) > engineBudget)
        #expect(DictationFinalizationDeadline.seconds(selection: .parakeetV2, audioDuration: 20) == 120)
        let final = try #require(DictationRecoveryText.select(rawText: "Final fixture", liveText: "Different partial"))
        #expect(final.transcript.text == "Final fixture")
        #expect(final.source == .authoritativeBatch)
        let partial = try #require(DictationRecoveryText.select(rawText: "", liveText: "Recovery fixture"))
        #expect(partial.source == .eouPreviewFallback)
        #expect(DictationRecoveryText.select(rawText: "", liveText: "  ") == nil)
    }

    @Test("deferred orphan sweep removes only unchanged launch candidates")
    func orphanSweep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OrphanSweepTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let orphan = directory.appendingPathComponent("local_dictation_recording_old.wav")
        let replaced = directory.appendingPathComponent("local-dictation-iphone-replayed.wav")
        let unrelated = directory.appendingPathComponent("unrelated.wav")
        for file in [orphan, replaced, unrelated] {
            try Data([0, 1]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        }
        let captured = TemporaryAudioOrphanSweep.capture(in: directory)
        let deferred = TemporaryAudioOrphanSweep.removeEligible(captured, now: now)
        #expect(deferred.count == 2)
        try Data([0, 1, 2]).write(to: replaced)
        let newRecording = directory.appendingPathComponent("local_dictation_recording_current.wav")
        try Data([3, 4]).write(to: newRecording)
        TemporaryAudioOrphanSweep.removeEligible(deferred, now: now.addingTimeInterval(3_601))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: replaced.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: newRecording.path))
    }

    @MainActor
    private func makeHistoryModel(
        _ store: HistoryStore,
        writeEdit: ((UUID, String?, Int64) async throws -> HistoryEntry)? = nil
    ) -> HistoryViewModel {
        HistoryViewModel(store: store, onCopy: { _ in }, onRepaste: { _ in }, onAddVocabularyCorrection: { _ in }, writeEdit: writeEdit)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Timed out waiting for the synthetic history operation")
    }
}

private actor EditGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
