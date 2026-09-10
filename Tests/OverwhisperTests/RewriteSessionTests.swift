import AppKit
import Testing
@testable import LocalDictation

private struct SessionWriter: ClipboardWriting {
    var fail = false
    func availabilityMessage() -> String? { nil }
    func rewrite(_ request: WritingRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        if fail { throw WritingFailure.failed }
        return request.source + " revised"
    }
}

@Suite("Selection rewrite sessions", .serialized)
@MainActor
struct RewriteSessionTests {
    private func model(fail: Bool = false) -> ClipboardRewriteModel {
        ClipboardRewriteModel(writer: SessionWriter(fail: fail), isDictationBusy: { false }, copy: { _ in true })
    }
    private func finish(_ model: ClipboardRewriteModel) async throws {
        for _ in 0..<200 {
            if !model.isRunning { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Rewrite did not settle")
    }

    @Test func versionsBoundMemoryAndKeepOriginal() {
        var session = RewriteSession(kind: .selection, original: "Original Friday")
        for n in 0..<10 { session.remember("Draft \(n)") }
        #expect(session.versions.count == 5)
        #expect(session.original == "Original Friday")
        #expect(session.move(-1) == "Draft 8")
        session.remember("Edited branch")
        #expect(session.versions.last == "Edited branch")
        #expect(!session.versions.contains("Draft 9"))
    }

    @Test func revisionsKeepEditedDraftAndImmutableOriginal() async throws {
        let m = model()
        m.loadSource("Deadline Friday", kind: .selection)
        m.start(); try await finish(m)
        m.result = "Manually edited draft"
        #expect(m.prepareRevision())
        #expect(m.source == "Manually edited draft")
        #expect(m.session.original == "Deadline Friday")
        m.instructions = "Restore the deadline"
        let request = WritingRequest(source: m.source, action: .custom, instructions: m.instructions, original: m.session.original)
        #expect(request.prompt.contains("Deadline Friday"))
        #expect(request.prompt.contains("Manually edited draft"))
        m.restoreDraft()
        #expect(m.result == "Manually edited draft" && m.isComplete)
    }

    @Test func failedRevisionRestoresCompletedText() async throws {
        let m = model(fail: true)
        m.loadClipboard("Original")
        m.reviewOriginal(); m.result = "Completed edited draft"
        #expect(m.prepareRevision())
        m.instructions = "Shorter"
        m.start(); try await finish(m)
        #expect(m.result == "Completed edited draft")
        #expect(m.isComplete && m.showingResult && m.message != nil)
    }

    @Test func originalReviewDoesNotOverwriteNewestVersion() async throws {
        let m = model()
        m.loadClipboard("Original")
        m.start(); try await finish(m)
        let latest = m.result
        m.reviewOriginal()
        #expect(m.result == "Original" && m.isOriginal)
        m.moveVersion(1)
        #expect(m.result == latest && !m.isOriginal)
        m.result = "Manual edits"
        #expect(!m.isOriginal)
    }

    @Test func replyRequiresDirectionAndKeepsCopyDefault() async throws {
        #expect(throws: WritingFailure.missingInstructions) {
            try WritingRequest(source: "Can you attend?", action: .reply, instructions: " ").validate()
        }
        let m = model()
        m.loadSource("Can you attend Friday?", kind: .selection)
        m.canReplaceSelection = true
        m.action = .reply; m.instructions = "Say I can attend"
        #expect(m.acceptTitle == "Copy & Close")
        m.start(); try await finish(m)
        #expect(m.prepareRevision())
        #expect(m.session.isReply && m.action == .reply)
        #expect(m.session.original == "Can you attend Friday?")
        #expect(m.acceptTitle == "Copy & Close")
    }

    @Test func totalContextIncludesOriginalAndCurrentText() {
        #expect(throws: WritingFailure.tooLong) {
            try WritingRequest(source: String(repeating: "a", count: 7000), action: .clean,
                               instructions: "", original: String(repeating: "b", count: 6000)).validate()
        }
        let same = String(repeating: "a", count: 12000)
        #expect(throws: Never.self) { try WritingRequest(source: same, action: .clean, instructions: "", original: same).validate() }
    }

    @Test func detachedDictationOffersCopyAndFreshSourceResetsCapabilities() {
        let m = model()
        m.loadSource("Dictation", kind: .dictation)
        #expect(m.acceptTitle == "Paste & Close")
        m.dictationCanPaste = false
        #expect(m.acceptTitle == "Copy & Close")
        m.canReplaceSelection = true
        m.loadClipboard("Another source")
        #expect(!m.canReplaceSelection && !m.dictationCanPaste)
    }

    @Test func onlyAcceptedNativeEditorProfileCanReplace() {
        func selection(_ bundle: String, terminal: Bool = false, role: String = kAXTextAreaRole, range: CFRange = CFRange(location: 2, length: 2)) -> RewriteSelection {
            RewriteSelection(pid: 1, bundleID: bundle, element: AXUIElementCreateApplication(1), text: "hi", range: range,
                             editable: true, terminal: terminal, role: role)
        }
        #expect(selection("com.apple.textedit").supportsReplacement)
        #expect(selection("com.apple.textedit").supportsInsertAfter)
        #expect(!selection("com.apple.textedit", terminal: true).supportsReplacement)
        #expect(!selection("com.apple.textedit", role: kAXButtonRole).supportsReplacement)
        #expect(!selection("com.apple.textedit", range: CFRange(location: -1, length: 0)).supportsReplacement)
        for bundle in ["com.apple.terminal", "com.tinyspeck.slackmacgap", "com.openai.codex", "com.apple.safari"] {
            #expect(!selection(bundle).supportsReplacement)
        }
    }

    @Test func failedPreflightDoesNotTouchClipboardOrPaste() async {
        let pb = NSPasteboard(name: .init("ld-selection-" + UUID().uuidString))
        defer { pb.releaseGlobally() }
        pb.setString("Unrelated clipboard", forType: .string)
        let count = pb.changeCount
        var pasted = false
        let inserter = TextInserter(pasteboard: pb, accessibilityPermission: { true }, pasteSimulator: { pasted = true; return true })
        _ = await inserter.insertText("Result", destination: nil, insertionGuard: InsertionGuard(preflight: { false }, beforePaste: { Issue.record("Should not validate again"); return true }))
        #expect(pb.changeCount == count)
        #expect(pb.string(forType: .string) == "Unrelated clipboard")
        #expect(!pasted)
    }

    @Test func changedSelectionAfterCopyNeverPastes() async throws {
        let pb = NSPasteboard(name: .init("ld-selection-" + UUID().uuidString))
        defer { pb.releaseGlobally() }
        var pasted = false
        let inserter = TextInserter(pasteboard: pb, accessibilityPermission: { true }, pasteSimulator: { pasted = true; return true })
        let destination = try #require(DictationDestination.captureFrontmost(candidateProvider: {
            .init(processIdentifier: 1, bundleIdentifier: "test", applicationName: "Test", role: kAXTextAreaRole,
                  subrole: nil, focusTokenAvailable: true, focusedElementIsEditable: true,
                  validateForInsertion: { _ in true }, remainsValidForInsertion: { true })
        }))
        let outcome = await inserter.insertText("Result", destination: destination,
            insertionGuard: InsertionGuard(preflight: { true }, beforePaste: { false }))
        #expect(!pasted)
        if case .clipboardOnly = outcome {} else { Issue.record("Expected recoverable clipboard result") }
    }

    @Test func concurrentClipboardChangeDuringFinalSelectionCheckNeverPastes() async throws {
        let pb = NSPasteboard(name: .init("ld-selection-" + UUID().uuidString))
        defer { pb.releaseGlobally() }
        var pasted = false
        let inserter = TextInserter(pasteboard: pb, accessibilityPermission: { true }, pasteSimulator: { pasted = true; return true })
        let destination = try #require(DictationDestination.captureFrontmost(candidateProvider: {
            .init(processIdentifier: 1, bundleIdentifier: "test", applicationName: "Test", role: kAXTextAreaRole,
                  subrole: nil, focusTokenAvailable: true, focusedElementIsEditable: true,
                  validateForInsertion: { _ in true }, remainsValidForInsertion: { true })
        }))
        _ = await inserter.insertText("Result", destination: destination,
            insertionGuard: InsertionGuard(preflight: { true }, beforePaste: {
                pb.clearContents(); pb.setString("New user copy", forType: .string); return true
            }))
        #expect(!pasted)
        #expect(pb.string(forType: .string) == "New user copy")
    }
    @Test func canceledAXLookupReturnsWithoutStackingMoreWork() async throws {
        let access = RewriteSelectionAccess(operationLimit: 0.01)
        let start = ContinuousClock.now
        let first = await access.perform(fallback: false) { _ in
            Thread.sleep(forTimeInterval: 0.12)
            return true
        }
        #expect(!first)
        #expect(start.duration(to: .now) < .milliseconds(100))
        let second = await access.perform(fallback: false) { _ in
            Issue.record("Busy AX executor must not enqueue another operation")
            return true
        }
        #expect(!second)
        try await Task.sleep(for: .milliseconds(150))
        let third = await access.perform(fallback: false) { _ in true }
        #expect(third)
    }

    @Test func manualOriginalEditsDoNotClaimModelProvenance() async throws {
        let m = model()
        m.loadSource("Original", kind: .dictation)
        m.reviewOriginal(); m.result = "Manual change"
        #expect(!m.usedLocalModel && !m.isOriginal)
        m.start(); try await finish(m)
        #expect(m.usedLocalModel)
        m.reviewOriginal()
        #expect(!m.usedLocalModel && m.isOriginal)
        m.moveVersion(1)
        #expect(m.usedLocalModel) // Return to the latest viewed draft.
        m.moveVersion(-1)
        #expect(!m.usedLocalModel) // Earlier manual snapshot remains available.
    }

    @Test func startingFromOriginalRetainsRecentDrafts() async throws {
        let m = model()
        m.loadClipboard("Original")
        m.start(); try await finish(m)
        let previous = m.result
        m.reviewOriginal()
        #expect(m.prepareRevision())
        #expect(m.session.versions.contains(previous))
    }

    @Test func localModelCanRestoreOriginalFactWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["LD_TEST_APPLE_WRITER"] == "1" else { return }
        let request = WritingRequest(source: "The fix is ready for review.", action: .custom,
            instructions: "Restore the planned Friday deployment from the original. Keep it concise.",
            original: "The fix is ready for review. Deployment is planned for Friday.")
        let result = try await AppleClipboardWriter().rewrite(request, onPartial: { _ in })
        #expect(result.lowercased().contains("friday"))
    }

    @Test func editedOriginalSurvivesNextAndReturnsToLastViewedDraft() async throws {
        let m = model()
        m.loadClipboard("Original")
        m.start(); try await finish(m)
        m.result = "First edited draft"
        #expect(m.prepareRevision())
        m.instructions = "Shorter"
        m.start(); try await finish(m)
        let latest = m.result
        m.reviewOriginal(); m.result = "Manual original correction"
        m.moveVersion(1)
        #expect(m.result == latest && m.usedLocalModel)
        m.moveVersion(1)
        #expect(m.result == "Manual original correction" && !m.usedLocalModel)
        #expect(m.session.original == "Original")
    }

    @Test func originalNavigationAtVersionLimitPreservesEditsAndBound() async throws {
        let m = model()
        m.loadClipboard("Original")
        for n in 0..<7 {
            m.instructions = "Version \(n)"; m.start(); try await finish(m)
            m.result = "Edited \(n)"
        }
        m.reviewOriginal(); m.result = "Original correction"
        m.moveVersion(1)
        #expect(m.result == "Edited 6")
        #expect(m.session.versions.count == 5)
        m.moveVersion(1)
        #expect(m.result == "Original correction" && !m.usedLocalModel)
    }

    @Test func completedManualEditsSurviveCloseAndRepeatedRecovery() async throws {
        let m = model()
        m.loadClipboard("Original"); m.start(); try await finish(m)
        m.result = "Newest manual edit"
        m.recoverForResume(); m.recoverForResume(); m.interruptForDictation()
        #expect(m.isComplete && m.result == "Newest manual edit")
        m.reviewOriginal(); m.moveVersion(1)
        #expect(m.result == "Newest manual edit")
    }

    @Test func rejectedRemoteAdmissionDoesNotAcquireOrPreempt() throws {
        let leases = InferenceLeaseCoordinator()
        #expect(leases.tryBeginRemote(localRewriteBusy: true) == nil)
        #expect(!leases.isBusy)
        let remote = try #require(leases.tryBeginRemote())
        #expect(leases.tryBeginRemote(localRewriteBusy: true) == nil)
        #expect(leases.isBusy)
        leases.endRemote(remote)
        #expect(!leases.isBusy)
        leases.beginDesktop()
        #expect(leases.tryBeginRemote() == nil)
        leases.endDesktop()
    }

    @Test func selectionClassificationNeverGuessesEmptyFromMissingAttributes() {
        for text: String? in [nil, ""] {
            if case .unavailable = RewriteSelectionAccess.classifyContent(range: nil, readText: { text }) {}
            else { Issue.record("Missing attributes must require explicit recovery") }
        }
        for range in [CFRange(location: -1, length: 2), CFRange(location: 0, length: -1),
                      CFRange(location: Int.max, length: 2), CFRange(location: 0, length: 12_001)] {
            if case .unavailable = RewriteSelectionAccess.classifyContent(range: range, readText: {
                Issue.record("Invalid range must not read text"); return nil
            }) {} else { Issue.record("Invalid range must be unavailable") }
        }
        if case .empty = RewriteSelectionAccess.classifyContent(range: CFRange(location: 2, length: 0), readText: {
            Issue.record("Collapsed range must not read text"); return nil
        }) {} else { Issue.record("Verified collapsed range must be empty") }
    }

    @Test func missingOrMismatchedRangeKeepsReadableTextCopyOnly() {
        for range: CFRange? in [nil, CFRange(location: 0, length: 1)] {
            guard case .selected(let text, let capturedRange) = RewriteSelectionAccess.classifyContent(range: range, readText: { "Hello" })
            else { Issue.record("Readable selected text should remain useful"); continue }
            #expect(text == "Hello" && capturedRange.location == -1)
        }
        guard case .selected(_, let range) = RewriteSelectionAccess.classifyContent(range: CFRange(location: 3, length: 2), readText: { "🐈" })
        else { Issue.record("UTF16 range must be supported"); return }
        #expect(range.location == 3 && range.length == 2)
        if case .unavailable = RewriteSelectionAccess.classifyContent(range: nil, readText: { String(repeating: "a", count: 12_001) }) {}
        else { Issue.record("Oversize text must be refused") }
    }

}
