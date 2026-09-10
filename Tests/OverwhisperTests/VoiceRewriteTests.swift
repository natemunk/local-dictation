import AppKit
import SwiftUI
import Carbon.HIToolbox
import Testing
@testable import LocalDictation

@MainActor
private final class FakeInstructionRecorder: RewriteInstructionRecording {
    var partial: ((String) -> Void)?
    var failure: (() -> Void)?
    var starts = 0
    var stops = 0
    var recording = false
    var rejectStart = false
    let url = URL(fileURLWithPath: "/tmp/synthetic-instruction-test.wav")
    func start(onPartial: @escaping (String) -> Void, onLevel: @escaping (Float) -> Void, onFailure: @escaping () -> Void) throws {
        if rejectStart { throw CancellationError() }
        starts += 1; recording = true; partial = onPartial; failure = onFailure
    }
    func stop() async throws -> URL { stops += 1; recording = false; return url }
    func cancel() { recording = false }
}

private struct VoiceTestWriter: ClipboardWriting {
    func availabilityMessage() -> String? { nil }
    func rewrite(_ request: WritingRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String {
        return request.source + " [" + request.instructions + "]"
    }
}

@Suite("Voice rewrite handoff")
@MainActor
struct VoiceRewriteTests {
    private func model() -> ClipboardRewriteModel {
        ClipboardRewriteModel(writer: VoiceTestWriter(), isDictationBusy: { false }, copy: { _ in Issue.record("No automatic copy"); return false })
    }
    private func settle(_ test: () -> Bool) async throws {
        for _ in 0..<200 {
            if test() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Voice flow did not settle")
    }

    @Test func clipboardInstructionsAreSeparateAndExplicitlyFinished() async throws {
        let model = model(), recorder = FakeInstructionRecorder()
        var calls = 0, deleted = 0
        let flow = VoiceRewriteFlow(model: model, recorder: recorder, deleteAudio: { _ in deleted += 1 }, transcribe: { _ in calls += 1; return "Make it concise" })
        flow.begin(source: "My message", dictation: false)
        recorder.partial?("Make it")
        #expect(model.source == "My message")
        #expect(model.instructions == "Make it")
        #expect(recorder.recording && calls == 0)
        flow.finish()
        try await settle { model.isComplete }
        #expect(model.result == "My message [Make it concise]")
        #expect(calls == 1 && deleted == 1 && !recorder.recording)
        flow.cancel()
    }

    @Test func waitsForSourceBeforeInstructionASRWithoutLosingSpokenText() async throws {
        let model = model(), recorder = FakeInstructionRecorder()
        var calls = 0
        let flow = VoiceRewriteFlow(model: model, recorder: recorder, deleteAudio: { _ in }, transcribe: { _ in calls += 1; return "Friendly" })
        flow.begin(source: nil, dictation: true)
        recorder.partial?("Friend")
        flow.finish()
        try await settle { recorder.stops == 1 }
        #expect(calls == 0 && flow.sourcePending)
        flow.resolveSource("Original dictation")
        try await settle { model.isComplete }
        #expect(model.result == "Original dictation [Friendly]")
        #expect(calls == 1)
        flow.cancel()
    }

    @Test func secondHyperCExpandsWithoutAutomaticallyRewriting() async throws {
        let model = model(), recorder = FakeInstructionRecorder()
        let flow = VoiceRewriteFlow(model: model, recorder: recorder, deleteAudio: { _ in }, transcribe: { _ in "Use bullets" })
        flow.begin(source: "Original", dictation: false)
        flow.expand()
        try await settle { flow.stage == .ready }
        #expect(flow.expanded && !recorder.recording)
        #expect(model.instructions == "Use bullets")
        #expect(!model.isRunning && !model.isComplete && model.result.isEmpty)
        flow.cancel()
    }

    @Test func cancelWhileWaitingForSourceDeletesOnlyInstructionAudio() async throws {
        let model = model(), recorder = FakeInstructionRecorder()
        var deleted: [URL] = []
        let flow = VoiceRewriteFlow(model: model, recorder: recorder, deleteAudio: { deleted.append($0) }, transcribe: { _ in Issue.record("Source not ready"); return "" })
        flow.begin(source: nil, dictation: true)
        flow.finish()
        try await settle { recorder.stops == 1 }
        await Task.yield()
        flow.cancel()
        try await settle { deleted.count == 1 }
        #expect(deleted == [recorder.url])
        #expect(!flow.isActive && !recorder.recording)
    }

    @Test func noSpeechLeavesPresetsAvailableAndDoesNotRunModel() async throws {
        let model = model(), recorder = FakeInstructionRecorder()
        let flow = VoiceRewriteFlow(model: model, recorder: recorder, deleteAudio: { _ in }, transcribe: { _ in "   " })
        flow.begin(source: "Original", dictation: false); flow.finish()
        try await settle { flow.stage == .ready }
        #expect(flow.expanded && model.action == .clean && !model.isComplete)
        #expect(flow.notice?.contains("No instruction speech") == true)
        flow.cancel()
    }

    @Test func failedCaptureKeepsSourceAndAllowsTypedInstructions() {
        let model = model(), recorder = FakeInstructionRecorder()
        recorder.rejectStart = true
        let flow = VoiceRewriteFlow(model: model, recorder: recorder, deleteAudio: { _ in }, transcribe: { _ in "" })
        flow.begin(source: "Preserved original", dictation: false)
        #expect(flow.stage == .ready && flow.expanded)
        #expect(model.source == "Preserved original" && !recorder.recording)
        flow.cancel()
    }

    @Test func recordingLimitStopsAndRequiresReview() async throws {
        let model = model(), recorder = FakeInstructionRecorder()
        let flow = VoiceRewriteFlow(model: model, recorder: recorder, limit: .milliseconds(20), deleteAudio: { _ in }, transcribe: { _ in "Summarize" })
        flow.begin(source: "Original", dictation: false)
        try await settle { flow.stage == .ready }
        #expect(flow.expanded && !model.isComplete && recorder.stops == 1)
        flow.cancel()
    }

    @Test func transcriptionTimeoutRetainsSourceAndRejectsLateInstructions() async throws {
        let model = model(), recorder = FakeInstructionRecorder()
        var resume: CheckedContinuation<String, Never>?
        let flow = VoiceRewriteFlow(model: model, recorder: recorder, transcriptionLimit: .milliseconds(25), deleteAudio: { _ in }, transcribe: { _ in await withCheckedContinuation { resume = $0 } })
        flow.begin(source: "Original", dictation: false)
        recorder.partial?("Live instructions")
        flow.finish()
        try await settle { flow.stage == .ready }
        #expect(flow.notice?.contains("timed out") == true)
        #expect(model.source == "Original" && model.instructions == "Live instructions")
        resume?.resume(returning: "Late instructions")
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.instructions == "Live instructions" && !model.isComplete)
        flow.cancel()
    }

    @Test func staleCaptureCallbacksCannotModifyNextSession() {
        let model = model(), recorder = FakeInstructionRecorder()
        let flow = VoiceRewriteFlow(model: model, recorder: recorder, deleteAudio: { _ in }, transcribe: { _ in "" })
        flow.begin(source: "First", dictation: false)
        let stale = recorder.partial
        flow.cancel()
        flow.begin(source: "Second", dictation: false)
        stale?("Stale")
        #expect(model.source == "Second" && model.instructions.isEmpty)
        flow.cancel()
    }

    @Test func handoffNeverInsertsAndHeldDReleaseCannotFinishTwice() {
        let coordinator = DictationCoordinator()
        _ = coordinator.hotkeyDown(at: 0, profileMode: .clean)
        let response = coordinator.finishForRewrite()
        guard case .finish(let request) = response.effects.first else { Issue.record("Missing handoff"); return }
        #expect(request.trigger == .rewrite && request.delivery == .preview && request.mode == .literal)
        #expect(coordinator.hotkeyUp(at: 2, profileMode: .clean).effects.isEmpty)
        #expect(coordinator.finishForRewrite().effects.isEmpty)
        #expect(coordinator.phase == .finalizing)
    }

    @Test func instructionLeaseDrainsBeforeNextDesktopASR() async throws {
        let leases = InferenceLeaseCoordinator()
        leases.beginDesktop()
        let lease = try #require(leases.tryBeginLocalInstructions())
        #expect(leases.tryBeginRemote() == nil)
        #expect(leases.tryBeginLocalInstructions() == nil)
        leases.endDesktop()
        leases.beginDesktop()
        await #expect(throws: (any Error).self) { try await leases.waitForRemoteRelease(timeout: .milliseconds(1)) }
        leases.endRemote(lease)
        try await leases.waitForRemoteRelease()
        leases.endDesktop()
        #expect(!leases.isBusy)
    }
    @Test func canceledRewriteStillFinishesOriginalIntoPreview() {
        let coordinator = DictationCoordinator()
        _ = coordinator.hotkeyDown(at: 0, profileMode: .clean)
        let response = coordinator.finishForRewrite()
        guard case .finish(let request) = response.effects.first else { Issue.record("Missing finish"); return }
        #expect(coordinator.cancelRewrite().effects.isEmpty)
        #expect(coordinator.phase == .finalizing)
        #expect(coordinator.transition(token: request.token, to: .previewing))
        #expect(coordinator.cancelRewrite().effects == [.previewOriginal(token: request.token)])
    }

    @Test func heldDToCHandoffDoesNotEmitAnInsertionFinish() throws {
        let coordinator = DictationCoordinator()
        var effects: [DictationCoordinatorEffect] = []
        let manager = HotkeyManager(coordinator: coordinator, profileMode: { .clean },
            effectHandler: { effects += $0 },
            onRewriteClipboard: { effects += coordinator.finishForRewrite().effects })
        let d = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_D), keyDown: true))
        d.flags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        #expect(manager.handle(type: .keyDown, event: d) == nil)
        let c = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true))
        c.flags = d.flags
        #expect(manager.handle(type: .keyDown, event: c) == nil)
        let up = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_D), keyDown: false))
        #expect(manager.handle(type: .keyUp, event: up) == nil)
        let requests = effects.compactMap { effect -> DictationFinishRequest? in
            if case .finish(let request) = effect { return request }; return nil
        }
        #expect(requests.count == 1)
        #expect(requests.first?.trigger == .rewrite && requests.first?.delivery == .preview)
    }

    @Test func emptyClipboardOrMenuOnlyHandoffDoesNotRecord() {
        let recorder = FakeInstructionRecorder()
        let flow = VoiceRewriteFlow(model: model(), recorder: recorder, deleteAudio: { _ in }, transcribe: { _ in "" })
        flow.begin(source: "", dictation: false)
        #expect(recorder.starts == 0 && flow.expanded && !flow.isBusy)
        flow.begin(source: nil, dictation: true, listen: false)
        #expect(recorder.starts == 0 && flow.sourcePending && flow.expanded)
        flow.resolveSource("Original")
        #expect(!flow.isBusy && flow.model.source == "Original")
        flow.cancel()
    }

    @Test func originalCanBeReviewedWithoutRunningTheModel() {
        let model = model()
        model.loadClipboard("Original message")
        model.reviewOriginal()
        #expect(model.result == "Original message" && model.isComplete && model.showingResult && model.isOriginal)
    }

    @Test func renderSyntheticVoicePopupWhenRequested() async throws {
        guard let prefix = ProcessInfo.processInfo.environment["LD_VOICE_PREVIEW_PREFIX"] else { return }
        _ = NSApplication.shared
        let model = model(), recorder = FakeInstructionRecorder()
        let flow = VoiceRewriteFlow(model: model, recorder: recorder, deleteAudio: { _ in }, transcribe: { _ in "Make it concise and friendlier." })
        flow.begin(source: "The search fix is ready for review. We plan to deploy it on Friday.", dictation: false)
        recorder.partial?("Make it concise and friendlier.")
        let view = NSHostingView(rootView: VoiceRewriteContainer(model: model, voice: flow,
            onDismiss: {}, onRefresh: {}, onAccept: {}, onResize: { _ in }))
        view.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        for phase in ["listening", "result", "options"] {
            if phase == "result" {
                flow.finish()
                try await settle { model.isComplete }
                window.setContentSize(NSSize(width: 560, height: 460))
            } else if phase == "options" {
                flow.expanded = true
                model.showingResult = false
                window.setContentSize(NSSize(width: 540, height: 640))
            }
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: prefix + "-" + phase + ".png"))
        }
        flow.cancel()
        window.orderOut(nil)
    }

    @Test func syntheticVoiceInstructionsReachRealLocalWriterWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["LD_TEST_APPLE_WRITER"] == "1" else { return }
        let model = ClipboardRewriteModel(isDictationBusy: { false }, copy: { _ in Issue.record("No clipboard write"); return false })
        let flow = VoiceRewriteFlow(model: model, recorder: FakeInstructionRecorder(), deleteAudio: { _ in },
            transcribe: { _ in "Make this shorter and friendly. Keep the number and planned day." })
        flow.begin(source: "The search fix is implemented, and all 12 tests passed. Deployment is planned for Friday, after review.", dictation: false)
        flow.finish()
        for _ in 0..<600 {
            if model.isComplete || model.message != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.isComplete)
        #expect(model.result.contains("12"))
        #expect(model.result.lowercased().contains("friday"))
        flow.cancel()
    }

    @Test func followupVoiceUsesEditedResultAndRetainsOriginal() async throws {
        let m = model(), recorder = FakeInstructionRecorder()
        let flow = VoiceRewriteFlow(model: m, recorder: recorder, deleteAudio: { _ in }, transcribe: { _ in "Restore Friday" })
        flow.begin(source: "Deadline Friday", dictation: false, listen: false, kind: .selection)
        m.reviewOriginal(); m.result = "Edited draft"
        flow.beginRevision()
        #expect(flow.isRevision && flow.stage == .listening)
        #expect(m.source == "Edited draft" && m.session.original == "Deadline Friday")
        flow.cancelOperation()
        #expect(!recorder.recording && m.isComplete && m.result == "Edited draft")
        #expect(flow.stage == .ready && m.showingResult)
    }

    @Test func dictationFollowupDoesNotWaitForSourceAgain() async throws {
        let m = model(), recorder = FakeInstructionRecorder()
        let flow = VoiceRewriteFlow(model: m, recorder: recorder, deleteAudio: { _ in }, transcribe: { _ in "Shorter" })
        flow.begin(source: nil, dictation: true)
        flow.resolveSource("Original dictated source")
        flow.finish()
        try await settle { m.isComplete }
        let first = m.result
        flow.beginRevision()
        #expect(!flow.sourcePending && flow.isDictationSource)
        flow.finish()
        try await settle { flow.stage == .ready && !m.isRunning }
        #expect(m.result == first + " [Shorter]")
        #expect(m.session.original == "Original dictated source")
    }

    @Test func unknownAndProtectedSourcesRequireExplicitClipboardChoice() {
        for result in [RewriteSelectionResult.unavailable, .protected] {
            let m = model(), recorder = FakeInstructionRecorder()
            let flow = VoiceRewriteFlow(model: m, recorder: recorder, transcribe: { _ in "" })
            var reads = 0
            let controller = ClipboardRewriteWindowController(model: m, voice: flow, isDictationBusy: { false },
                readClipboard: { reads += 1; return "Synthetic clipboard" })
            controller.prepareSource(result, listen: true)
            #expect(reads == 0 && recorder.starts == 0)
            #expect(!m.hasContentToDiscard && m.session.kind == .manual)
            controller.useClipboard()
            #expect(reads == 1 && recorder.starts == 1 && flow.stage == .listening)
            #expect(m.source == "Synthetic clipboard" && m.session.kind == .clipboard)
            flow.cancel()
        }
    }

    @Test func explicitOptionsRecoveryDoesNotUnexpectedlyStartMic() {
        let m = model(), recorder = FakeInstructionRecorder()
        let flow = VoiceRewriteFlow(model: m, recorder: recorder, transcribe: { _ in "" })
        let controller = ClipboardRewriteWindowController(model: m, voice: flow, isDictationBusy: { false },
            readClipboard: { "Synthetic clipboard" })
        controller.prepareSource(.unavailable, listen: false)
        controller.useClipboard()
        #expect(recorder.starts == 0 && flow.stage == .ready)
        m.instructions = "Keep these instructions"
        #expect(m.hasContentToDiscard)
        flow.cancel()
    }

    @Test func emptyAndExcludedOwnProcessUseClipboardWithoutSelectionRead() {
        for result in [RewriteSelectionResult.empty, .excludedOwnProcess] {
            let m = model(), recorder = FakeInstructionRecorder()
            let flow = VoiceRewriteFlow(model: m, recorder: recorder, transcribe: { _ in "" })
            var reads = 0
            let controller = ClipboardRewriteWindowController(model: m, voice: flow, isDictationBusy: { false },
                readClipboard: { reads += 1; return "Synthetic clipboard" },
                captureDestination: { Issue.record("Must not inspect destination"); return nil })
            controller.prepareSource(result, listen: false)
            #expect(reads == 1 && m.session.kind == .clipboard && recorder.starts == 0)
            flow.cancel()
        }
    }

    @Test func readableSelectionTakesPriorityOverClipboardWithoutRange() {
        let m = model(), recorder = FakeInstructionRecorder()
        let flow = VoiceRewriteFlow(model: m, recorder: recorder, transcribe: { _ in "" })
        let controller = ClipboardRewriteWindowController(model: m, voice: flow, isDictationBusy: { false },
            readClipboard: { Issue.record("Selected text must win"); return nil },
            captureDestination: { nil }, frontmostPID: { 42 })
        let selection = RewriteSelection(pid: 42, bundleID: "test.editor", element: AXUIElementCreateApplication(42),
            text: "Synthetic selected text", range: CFRange(location: -1, length: 0), editable: true, terminal: false, role: kAXTextAreaRole)
        #expect(controller.prepareSource(.selected(selection), listen: false))
        #expect(m.source == "Synthetic selected text" && m.session.kind == .selection)
        #expect(!m.canReplaceSelection && !m.canInsertAfterSelection && recorder.starts == 0)
        flow.cancel()
    }

    @Test func rewriteReturnAndEscapeConsumeMatchingKeyUpsOnlyWhenHandled() throws {
        for code in [kVK_Return, kVK_Escape] {
            var handled = true, calls = 0
            let manager = HotkeyManager(coordinator: DictationCoordinator(), profileMode: { .clean }, effectHandler: { _ in },
                onRewriteEnter: { calls += 1; return handled }, onRewriteEscape: { calls += 1; return handled })
            func event(_ down: Bool) throws -> CGEvent {
                let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down))
                event.flags = []
                return event
            }
            #expect(manager.handle(type: .keyDown, event: try event(true)) == nil)
            #expect(manager.handle(type: .keyUp, event: try event(false)) == nil)
            #expect(calls == 1)
            handled = false
            #expect(manager.handle(type: .keyDown, event: try event(true)) != nil)
            #expect(manager.handle(type: .keyUp, event: try event(false)) != nil)
            #expect(calls == 2)
        }
    }

}
