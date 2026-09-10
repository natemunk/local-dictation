import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import LocalDictation

private struct TestWriter: ClipboardWriting {
    var unavailable: String? = nil
    var operation: @Sendable (WritingRequest, @escaping @Sendable (String) async -> Void) async throws -> String = { _, partial in
        await partial("A")
        await partial("A complete")
        return "A complete result."
    }
    func availabilityMessage() -> String? { unavailable }
    func rewrite(_ request: WritingRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        try await operation(request, onPartial)
    }
}

private actor SuspendedWriter: ClipboardWriting {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    nonisolated func availabilityMessage() -> String? { nil }
    func rewrite(_ request: WritingRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        started = true
        await onPartial("Incomplete")
        // Deliberately ignores cancellation: exercise stale-response/drain safety.
        await withCheckedContinuation { continuation = $0 }
        await onPartial("Late stale partial")
        return "Late stale final"
    }
    func finish() { continuation?.resume(); continuation = nil }
}

@Suite("Clipboard rewrite")
@MainActor
struct ClipboardRewriteTests {
    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for rewrite state")
    }

    @Test func validatesWithoutTruncatingOrSending() throws {
        #expect(throws: WritingFailure.emptySource) { try WritingRequest(source: " \n", action: .clean, instructions: "").validate() }
        #expect(throws: WritingFailure.missingInstructions) { try WritingRequest(source: "text", action: .custom, instructions: " ").validate() }
        #expect(throws: WritingFailure.tooLong) { try WritingRequest(source: String(repeating: "你", count: 4001), action: .clean, instructions: "").validate() }
        #expect(throws: WritingFailure.instructionsTooLong) { try WritingRequest(source: "text", action: .clean, instructions: String(repeating: "x", count: 1001)).validate() }
    }

    @Test func requestBoundaryAndPresets() {
        for action in WritingAction.allCases {
            let request = WritingRequest(source: "SOURCE_SENTINEL_123", action: action, instructions: "Be gentler")
            #expect(!request.rules.contains(request.source))
            #expect(request.rules.contains("Be gentler"))
            #expect(request.rules.contains("untrusted content"))
            #expect(!action.instruction.isEmpty)
        }
        #expect(WritingAction.update.instruction.contains("Distinguish implemented, tested, deployed, and planned"))
    }

    @Test func streamsSnapshotsAndCopiesOnlyAcceptedEdits() async throws {
        var copies: [String] = []
        let model = ClipboardRewriteModel(writer: TestWriter(), isDictationBusy: { false }, copy: { copies.append($0); return true })
        model.loadClipboard("Original")
        model.start()
        #expect(copies.isEmpty)
        #expect(!model.copyResult())
        try await settle { model.isComplete }
        #expect(model.result == "A complete result.")
        #expect(copies.isEmpty)
        model.result = "My edited result"
        #expect(model.copyResult())
        #expect(copies == ["My edited result"])
        #expect(model.source == "Original")
    }

    @Test func copyFailureRetainsResult() async throws {
        let model = ClipboardRewriteModel(writer: TestWriter(), isDictationBusy: { false }, copy: { _ in false })
        model.loadClipboard("Original")
        model.start()
        try await settle { model.isComplete }
        #expect(!model.copyResult())
        #expect(model.result == "A complete result.")
        #expect(model.message == PreviewNotice.copyFailureMessage)
    }

    @Test func busyAndUnavailableNeverStartProvider() {
        let writer = TestWriter(operation: { _, _ in Issue.record("Must not start"); return "" })
        let busy = ClipboardRewriteModel(writer: writer, isDictationBusy: { true }, copy: { _ in false })
        busy.loadClipboard("Original"); busy.start()
        #expect(!busy.isRunning)
        #expect(busy.message?.contains("Finish dictation") == true)
        let offline = ClipboardRewriteModel(writer: TestWriter(unavailable: "Model unavailable", operation: writer.operation), isDictationBusy: { false }, copy: { _ in false })
        offline.loadClipboard("Original"); offline.start()
        #expect(offline.message == "Model unavailable")
        #expect(!offline.isRunning)
    }

    @Test func preemptionRejectsLateResultsAndWaitsForDrain() async throws {
        let writer = SuspendedWriter()
        let model = ClipboardRewriteModel(writer: writer, isDictationBusy: { false }, copy: { _ in Issue.record("No copy"); return true })
        model.loadClipboard("Original")
        model.instructions = "My instructions"
        model.start()
        try await settle { model.result == "Incomplete" }
        model.interruptForDictation()
        #expect(!model.isRunning)
        #expect(!model.copyResult())
        #expect(model.instructions == "My instructions")
        #expect(model.message?.contains("priority") == true)
        model.loadClipboard("Replacement")
        model.start()
        #expect(model.message?.contains("stopping") == true)
        await writer.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.source == "Replacement")
        #expect(model.result.isEmpty)
        #expect(!model.isComplete)
    }

    @Test func closeDuringRevisionRestoresEditedDraftAndRejectsLateOutput() async throws {
        let writer = SuspendedWriter()
        let model = ClipboardRewriteModel(writer: writer, isDictationBusy: { false }, copy: { _ in true })
        model.loadClipboard("Original")
        model.reviewOriginal(); model.result = "Keep this manual edit"
        #expect(model.prepareRevision())
        let version = model.session.versionIndex
        model.instructions = "Shorter"; model.start()
        try await settle { model.result == "Incomplete" }
        let controller = ClipboardRewriteWindowController(model: model, isDictationBusy: { false }, readClipboard: { nil })
        controller.dismiss(restoreFocus: false)
        #expect(model.isComplete && model.showingResult)
        #expect(model.result == "Keep this manual edit" && !model.usedLocalModel)
        #expect(model.session.versionIndex == version)
        #expect(model.blocksRemoteInference)
        await writer.finish()
        try await settle { !model.blocksRemoteInference }
        #expect(model.result == "Keep this manual edit")
    }

    @Test func firstGenerationCloseReopensSourceWithoutAcceptingPartial() async throws {
        let writer = SuspendedWriter()
        let model = ClipboardRewriteModel(writer: writer, isDictationBusy: { false }, copy: { _ in true })
        model.loadClipboard("Original"); model.start()
        try await settle { model.result == "Incomplete" }
        model.recoverForResume()
        #expect(!model.showingResult && !model.isComplete && !model.copyResult())
        #expect(model.source == "Original")
        await writer.finish()
        try await settle { !model.blocksRemoteInference }
    }

    @Test func deadlineCancelsWithoutAcceptingPartial() async throws {
        let writer = SuspendedWriter()
        let model = ClipboardRewriteModel(writer: writer, deadline: .milliseconds(40), isDictationBusy: { false }, copy: { _ in false })
        model.loadClipboard("Original"); model.start()
        try await settle { !model.isRunning }
        #expect(model.message?.contains("too long") == true)
        #expect(!model.isComplete)
        #expect(model.source == "Original")
        await writer.finish()
    }

    @Test func providerFailureDoesNotExposeDynamicError() async throws {
        struct PrivateError: Error, CustomStringConvertible { var description: String { "PRIVATE_ERROR_SENTINEL" } }
        let model = ClipboardRewriteModel(writer: TestWriter(operation: { _, _ in throw PrivateError() }), isDictationBusy: { false }, copy: { _ in false })
        model.loadClipboard("Original"); model.start()
        try await settle { !model.isRunning }
        #expect(model.message == WritingFailure.failed.message)
        #expect(!model.isComplete)
    }

    @Test func emptyClipboardAndArrowBounds() {
        let model = ClipboardRewriteModel(writer: TestWriter(), isDictationBusy: { false }, copy: { _ in false })
        model.loadClipboard(nil)
        #expect(model.message == WritingFailure.emptySource.message)
        model.moveSelection(-1); #expect(model.action == .clean)
        model.moveSelection(100); #expect(model.action == .custom)
        model.moveSelection(-1); #expect(model.action == .reply)
    }

    @Test func hyperCConsumesDownRepeatAndModifierlessUp() throws {
        let coordinator = DictationCoordinator()
        var invoked = 0
        let manager = HotkeyManager(coordinator: coordinator, profileMode: { .clean }, effectHandler: { _ in }, onRewriteClipboard: { invoked += 1 })
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true))
        down.flags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        #expect(manager.handle(type: .keyDown, event: down) == nil)
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        #expect(manager.handle(type: .keyDown, event: down) == nil)
        #expect(invoked == 1)
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false))
        up.flags = []
        #expect(manager.handle(type: .keyUp, event: up) == nil)
        #expect(!coordinator.phase.hasActiveSession)
    }

    @Test func hyperCDuringDictationRequestsTheRewriteHandoff() throws {
        let coordinator = DictationCoordinator()
        _ = coordinator.hotkeyDown(at: 0, profileMode: .clean)
        _ = coordinator.hotkeyUp(at: 0.1, profileMode: .clean)
        let manager = HotkeyManager(coordinator: coordinator, profileMode: { .clean }, effectHandler: { _ in Issue.record("No dictation effects") }, onRewriteClipboard: { _ = coordinator.finishForRewrite() })
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true))
        down.flags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        #expect(manager.handle(type: .keyDown, event: down) == nil)
        #expect(coordinator.phase == .finalizing)
    }

    @Test func ordinaryCStillPassesThroughAfterLostKeyUp() throws {
        let manager = HotkeyManager(coordinator: DictationCoordinator(), profileMode: { .clean }, effectHandler: { _ in })
        let down = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true))
        down.flags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        #expect(manager.handle(type: .keyDown, event: down) == nil)
        down.flags = [.maskCommand]
        #expect(manager.handle(type: .keyDown, event: down) != nil)
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false))
        #expect(manager.handle(type: .keyUp, event: up) != nil)
    }

    @Test func renderSyntheticPopupWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["LD_REWRITE_PREVIEW_PATH"] else { return }
        _ = NSApplication.shared
        let model = ClipboardRewriteModel(writer: TestWriter(), isDictationBusy: { false }, copy: { _ in true })
        model.loadClipboard("The new search flow is implemented and the tests pass. Deployment is planned for tomorrow, pending review.")
        let view = NSHostingView(rootView: ClipboardRewriteView(model: model, onDismiss: {}, onRefresh: {}))
        view.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }

    @Test func realAppleModelWithSyntheticTextWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["LD_TEST_APPLE_WRITER"] == "1" else { return }
        let writer = AppleClipboardWriter()
        #expect(writer.availabilityMessage() == nil)
        let request = WritingRequest(source: "The search fix is implemented. All 12 tests passed. It has not been deployed. Review is planned for Friday.", action: .update, instructions: "Keep it under 60 words.")
        let output = try await CleanupDeadline.run(for: .seconds(45)) {
            try await writer.rewrite(request, onPartial: { _ in })
        }
        #expect(!output.isEmpty)
        #expect(output.contains("12"))
        #expect(output.lowercased().contains("friday"))
        // Synthetic only; never print actual model output to diagnostics.
    }
}
