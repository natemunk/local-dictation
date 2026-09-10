import AppKit
import SwiftUI

private final class RewritePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipboardRewriteWindowController: NSObject, NSWindowDelegate {
    let model: ClipboardRewriteModel
    private var panel: NSPanel?
    private var previousApp: NSRunningApplication?
    private let voice: VoiceRewriteFlow?
    private let selectionAccess = RewriteSelectionAccess()
    private var selection: RewriteSelection?
    private var selectionDestination: DictationDestination?
    private var invocation = UUID()
    private var lookupPending = false
    private var expandPending = false
    private var clipboardRecoveryListens = false
    private var deliveryTask: Task<Void, Never>?
    var deliverSelection: ((String, DictationDestination?, InsertionGuard) async -> InsertionOutcome)?
    var onCopyDictation: (() -> Void)?
    var isVisible: Bool { panel?.isVisible == true }

    func beginFromFrontmost(listen: Bool = true) {
        guard !isDictationBusy() else { return }
        if lookupPending { expandPending = true; return }
        invocation = UUID()
        let id = invocation
        lookupPending = true
        expandPending = !listen
        let sourcePID = frontmostPID()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.selectionAccess.captureFrontmost()

            guard self.invocation == id else { return }
            self.lookupPending = false
            guard !self.isDictationBusy() else { return }
            guard self.frontmostPID() == sourcePID else {
                NSSound.beep() // Do not steal focus from the app the user just chose.
                return
            }
            guard self.prepareSource(result, listen: !self.expandPending) else { return }
            self.show(allowDuringDictation: true)
        }
    }

    @discardableResult
    func prepareSource(_ result: RewriteSelectionResult, listen shouldListen: Bool) -> Bool {
        self.selection = nil
        self.selectionDestination = nil
        self.clipboardRecoveryListens = false
        switch result {
        case .selected(let captured):
            self.selection = captured
            guard self.frontmostPID() == captured.pid else { NSSound.beep(); return false }
            self.selectionDestination = self.captureDestination()
            self.voice?.begin(source: captured.text, dictation: false, listen: shouldListen, kind: .selection)
            self.model.canReplaceSelection = captured.supportsReplacement && self.selectionDestination?.insertionTier == .exactEditableElement
            self.model.canInsertAfterSelection = captured.supportsInsertAfter && self.model.canReplaceSelection
            if !self.model.canReplaceSelection {
                self.model.setNotice("Selected text captured. This editor supports Copy; replacement has not been verified.")
            }
        case .empty, .excludedOwnProcess:
            self.voice?.begin(source: self.readClipboard(), dictation: false, listen: shouldListen)
            if case .excludedOwnProcess = result {
                self.model.setNotice("Using your clipboard. Text inside Local Dictation is not read automatically.")
            }
        case .unavailable, .protected:
            self.clipboardRecoveryListens = shouldListen
            self.voice?.begin(source: nil, dictation: false, listen: false, kind: .manual)
            self.model.setNotice(result.isProtected
                ? "Protected fields cannot be read. Choose Use current clipboard to continue, or type source text."
                : "Couldn’t read the selection. Choose Use current clipboard to continue, or type source text.")
        }
        if self.clipboardRecoveryListens {
            self.model.setNotice((self.model.message ?? "") + " Using the clipboard will start instruction recording.")
        }
        return true
    }

    func handleActiveHotkey() {
        guard !model.isDelivering else { return }
        if voice?.stage == .ready, model.showingResult, model.isComplete, !model.isRunning {
            voice?.beginRevision()
            show(allowDuringDictation: true)
        } else { expand() }
    }

    func resume() {
        guard model.hasDraft, !model.isDelivering, !isDictationBusy() else { return }
        model.recoverForResume()
        voice?.resume()
        show()
    }

    var onDismiss: () -> Void = {}
    var onAccept: (() -> Void)?
    var isKeyWindow: Bool { panel?.isKeyWindow == true }
    private let readClipboard: () -> String?
    private let frontmostPID: @MainActor () -> pid_t?
    private let captureDestination: @MainActor () -> DictationDestination?
    private let isDictationBusy: () -> Bool

    init(model: ClipboardRewriteModel, voice: VoiceRewriteFlow? = nil, isDictationBusy: @escaping () -> Bool,
         readClipboard: @escaping () -> String? = { NSPasteboard.general.string(forType: .string) },
         captureDestination: @escaping @MainActor () -> DictationDestination? = { DictationDestination.captureFrontmost() },
         frontmostPID: @escaping @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.model = model
        self.voice = voice
        self.isDictationBusy = isDictationBusy
        self.readClipboard = readClipboard
        self.captureDestination = captureDestination
        self.frontmostPID = frontmostPID
    }

    func show(allowDuringDictation: Bool = false) {
        // Never steal the captured destination's focus during dictation.
        guard allowDuringDictation || !isDictationBusy() else { NSSound.beep(); return }
        if panel?.isVisible != true {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        if !model.hasDraft { model.loadClipboard(readClipboard()) }
        let nonactivating = model.session.kind == .selection

        if let existing = panel, existing.styleMask.contains(.nonactivatingPanel) != nonactivating {
            existing.orderOut(nil)
            panel = nil
        }
        if panel == nil {
            var style: NSWindow.StyleMask = [.titled, .closable, .resizable, .utilityWindow]
            if nonactivating { style.insert(.nonactivatingPanel) }
            let panel = RewritePanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
                                styleMask: style,
                                backing: .buffered, defer: false)
            panel.title = "Rewrite Clipboard"
            panel.minSize = NSSize(width: 420, height: 260)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.delegate = self
            if let voice {

                panel.contentView = NSHostingView(rootView: VoiceRewriteContainer(
                    model: model, voice: voice,
                    onDismiss: { [weak self] in self?.dismiss() },
                    onRefresh: { [weak self] in self?.refreshClipboard() },
                    onAccept: { [weak self] in self?.accept() },
                    onResize: { [weak self] compact in self?.resize(compact: compact) },
                    onCopy: { [weak self] in self?.copyAcceptedResult() },
                    onInsertAfter: { [weak self] in self?.acceptSelection(insertAfter: true) }
                ))
            } else {
                panel.contentView = NSHostingView(rootView: ClipboardRewriteView(
                    model: model,
                    onDismiss: { [weak self] in self?.dismiss() },
                    onRefresh: { [weak self] in self?.refreshClipboard() }
                ))
            }
            panel.center()
            self.panel = panel
        }
        panel?.title = "Rewrite · " + model.session.kind.rawValue.capitalized
        resize(compact: voice?.isActive == true && voice?.expanded == false)
        panel?.makeKeyAndOrderFront(nil)
        if !nonactivating { NSApp.activate(ignoringOtherApps: true) }
    }

    func expand() {
        guard !model.isDelivering else { return }
        voice?.expand()
        show(allowDuringDictation: true)
        resize(compact: false)
    }

    func finishVoice() -> Bool {
        guard isKeyWindow, voice?.stage == .listening || voice?.stage == .transcribing else { return false }
        voice?.finish()
        return true
    }

    func escapeVoice() -> Bool {
        guard isKeyWindow, voice?.isActive == true else { return false }
        let id = voice?.operationID
        Task { @MainActor [weak self] in
            guard let self, self.voice?.operationID == id else { return }
            if self.voice?.sourcePending == true { self.dismiss() }
            else if self.voice?.isBusy == true || self.model.isRunning {
                self.voice?.cancelOperation()
            } else { self.dismiss() }
        }
        return true
    }

    private func accept() {
        guard !model.isDelivering else { return }
        if model.isReply { copyAcceptedResult() }
        else if model.canReplaceSelection { acceptSelection() }
        else if model.dictationCanPaste, let onAccept { onAccept() }
        else { copyAcceptedResult() }
    }

    private func copyAcceptedResult() {
        guard !model.isDelivering else { return }
        if model.dictationCanPaste, let onCopyDictation { onCopyDictation(); return }
        if model.copyResult() { dismiss() }
    }

    func acceptSelection(insertAfter: Bool = false) {
        guard model.isComplete, !model.isRunning, !model.isDelivering, !model.isReply,
              !model.result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let selection, selection.supportsReplacement,
              !insertAfter || selection.supportsInsertAfter,
              let deliverSelection else { return }
        let sessionID = model.session.id
        let id = invocation
        let text = (insertAfter ? "\n\n" : "") + model.result
        model.isDelivering = true
        // A nonactivating key panel must relinquish key focus before synthetic paste.
        panel?.orderOut(nil)
        deliveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.model.isDelivering = false; self.deliveryTask = nil }
            let valid: @MainActor () -> Bool = {
                self.invocation == id && self.model.session.id == sessionID && !Task.isCancelled
            }
            let guardChecks = InsertionGuard(preflight: {
                guard valid(), let app = NSRunningApplication(processIdentifier: selection.pid), !app.isTerminated else { return false }
                if !app.isActive { app.activate() }
                guard await self.selectionAccess.validate(selection), valid() else { return false }
                return true
            }, beforePaste: {
                guard valid() else { return false }
                if insertAfter { return await self.selectionAccess.collapseAfter(selection) && valid() }
                return await self.selectionAccess.validate(selection) && valid()
            })
            let outcome = await deliverSelection(text, self.selectionDestination, guardChecks)
            guard valid() else { return }
            switch outcome {
            case .pasteEventSent:
                self.model.canReplaceSelection = false
                self.model.canInsertAfterSelection = false
                self.selection = nil
                self.model.setNotice("Paste sent. The result is also on your clipboard. Resume this draft from the menu if needed.")
                self.dismiss(restoreFocus: false)
            case .clipboardOnly(let reason), .historyOnly(let reason):
                self.model.setNotice(reason + " Your draft is still here.")
                self.show(allowDuringDictation: true)

            case .cancelled:
                self.model.setNotice("Insertion canceled. Your draft is still here.")
                self.show(allowDuringDictation: true)

            }
        }
    }

    private func resize(compact: Bool) {
        guard let panel else { return }
        let size = compact ? NSSize(width: 560, height: model.showingResult ? 460 : 320) : NSSize(width: 540, height: 640)
        panel.setContentSize(size)
    }

    func useClipboard() {
        guard !model.isDelivering, !isDictationBusy() else { return }
        let listen = clipboardRecoveryListens
        clipboardRecoveryListens = false
        selection = nil
        selectionDestination = nil
        if let voice { voice.begin(source: readClipboard(), dictation: false, listen: listen) }
        else { model.loadClipboard(readClipboard()) }
    }

    private func refreshClipboard() {
        guard !model.hasContentToDiscard else { confirmClipboardReplacement(); return }
        useClipboard()
        show(allowDuringDictation: true)
    }

    private func confirmClipboardReplacement() {
        guard let panel else { return }
        let alert = NSAlert()
        alert.messageText = "Replace this draft with the current clipboard?"
        alert.informativeText = "The source, instructions, and result in this window will be cleared. Your clipboard will not change."
        alert.addButton(withTitle: "Use Clipboard")
        alert.addButton(withTitle: "Keep Draft")
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.useClipboard()
            self.show(allowDuringDictation: true)

        }
    }

    func dismiss(restoreFocus: Bool = true, notify: Bool = true) {
        invocation = UUID()
        lookupPending = false
        deliveryTask?.cancel()
        voice?.cancel()
        model.recoverForResume()
        let wasKey = panel?.isKeyWindow == true
        panel?.orderOut(nil)
        if restoreFocus, wasKey, let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        }
        // The callback may open raw dictation Preview; never restore focus after it.
        if notify { model.dictationCanPaste = false; onDismiss() }
    }

    func interruptForDictation() {
        invocation = UUID()
        lookupPending = false
        model.interruptForDictation()
        // Desktop destinations are resolved at finish. Restore only if this
        // panel still owned focus; never interrupt a newly selected app.
        dismiss(notify: false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false // Retain the draft only in this app session's memory.
    }
}

private struct RewriteResultTools: View {
    @ObservedObject var model: ClipboardRewriteModel
    var onCopy: () -> Void
    var onInsertAfter: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button("Previous") { model.moveVersion(-1) }.disabled(!model.canGoPrevious)
                Button("Next") { model.moveVersion(1) }.disabled(!model.canGoNext)
                Button("Original") { model.reviewOriginal() }
                Spacer()
                if model.acceptTitle != "Copy & Close" { Button("Copy & Close", action: onCopy) }
                if model.canInsertAfterSelection && !model.isReply {
                    Button("Insert after selection", action: onInsertAfter)
                }
            }
            .disabled(model.isRunning || !model.isComplete || model.isDelivering)
            if model.canReplaceSelection && !model.isReply {
                Text("Replace and Insert use your clipboard and leave the result there.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ClipboardRewriteView: View {
    @ObservedObject var model: ClipboardRewriteModel
    let onDismiss: () -> Void
    let onRefresh: () -> Void
    var onAccept: (() -> Void)? = nil
    var title = "Rewrite Clipboard"
    var inputBusy = false
    var voiceNotice: String? = nil
    var allowsRefresh = true
    var onCopy: (() -> Void)? = nil
    var onInsertAfter: () -> Void = {}
    private enum Focus: Hashable { case presets, instructions, source, result }
    @FocusState private var focus: Focus?
    @State private var sourceExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                Label("On-device", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.sourceLabel).font(.caption).foregroundStyle(.secondary)
            if let message = model.message ?? voiceNotice {
                Label(message, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rewrite.notice")
            }
            if model.showingResult {
                HStack {
                    Text(model.usedLocalModel ? model.action.title : "Review text").font(.headline)
                    Spacer()
                    if model.isRunning { ProgressView().controlSize(.small); Text("Rewriting…").font(.caption) }
                    else if !model.isComplete { Text("Incomplete result").font(.caption).foregroundStyle(.secondary) }
                }
                TextEditor(text: $model.result)
                    .font(.body).padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .focused($focus, equals: .result)
                    .disabled(model.isRunning || model.isDelivering || inputBusy)
                    .accessibilityLabel("Rewrite result")
                    .accessibilityIdentifier("rewrite.result")
                RewriteResultTools(model: model, onCopy: onCopy ?? { if model.copyResult() { onDismiss() } }, onInsertAfter: onInsertAfter)
                Text("Review before accepting. Names, numbers, and meaning can still need a correction.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Back") { model.cancel(); model.showingResult = false; focus = .presets }.disabled(model.isDelivering || inputBusy)
                    if model.isRunning {
                        Button("Cancel Rewrite") { model.cancel(); model.restoreDraft() }
                    } else {
                        Button("Retry") { model.start() }.disabled(inputBusy || model.isDelivering)
                    }
                    Spacer()
                    Button(model.acceptTitle) { if let onAccept { onAccept() } else if model.copyResult() { onDismiss() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.isComplete || model.isRunning || model.isDelivering || model.result.isEmpty)
                }
            } else {
                DisclosureGroup("Source text", isExpanded: $sourceExpanded) {
                    TextEditor(text: $model.source)
                        .font(.body).frame(height: 95)
                        .focused($focus, equals: .source)
                        .accessibilityLabel("Source text")
                        .disabled(inputBusy)
                }
                if !sourceExpanded {
                    Text(model.source.isEmpty ? "No text copied yet" : String(model.source.prefix(180)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(WritingAction.allCases) { action in
                                Button {
                                    model.action = action
                                    focus = .presets
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: model.action == action ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(model.action == action ? Color.accentColor : Color.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(action.title).fontWeight(.medium)
                                            Text(action.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(7).contentShape(Rectangle())
                                    .background(model.action == action ? Color.accentColor.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                                .accessibilityAddTraits(model.action == action ? .isSelected : [])
                                .id(action)
                            }
                        }
                    }
                    .disabled(inputBusy || model.isDelivering)
                    .focusable().focused($focus, equals: .presets)
                    .accessibilityLabel("Rewrite presets. Use up and down arrows to select, Return to rewrite.")
                    .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                    .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                    .onKeyPress(.return) {
                        guard !inputBusy else { return .handled }
                        if (model.action == .custom || model.action == .reply) && model.instructions.isEmpty { focus = .instructions }
                        else { model.start() }
                        return .handled
                    }
                    .onChange(of: model.action) { _, selected in proxy.scrollTo(selected) }
                    .onAppear { proxy.scrollTo(model.action) }
                }
                Text("Any extra instructions?").font(.caption.weight(.medium))
                TextField("e.g. a little softer, or under three sentences", text: $model.instructions, axis: .vertical)
                    .lineLimit(2...3).textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .instructions)
                    .accessibilityIdentifier("rewrite.instructions")
                    .disabled(inputBusy || model.isDelivering)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers == .shift {
                            guard !inputBusy, !model.isDelivering,
                                  let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .handled }
                            editor.insertNewlineIgnoringFieldEditor(nil)
                            return .handled
                        }
                        guard press.modifiers.isEmpty else { return .ignored }
                        if !inputBusy, !model.isDelivering { model.start() }
                        return .handled
                    }
                HStack {
                    Button("Use current clipboard…", action: onRefresh).disabled(inputBusy || !allowsRefresh)
                    if model.isComplete { Button("Return to result") { model.showingResult = true }.disabled(inputBusy) }
                    Button("Review original") { model.reviewOriginal() }.disabled(inputBusy || model.source.isEmpty)
                    Spacer()
                    Button("Rewrite") { model.start() }
                        .disabled(inputBusy)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            Divider()
            HStack {
                Text(model.showingResult ? "⌘↩ Accept · Hyper+C revise · Esc dismiss" : "↑↓ Choose · Return rewrite · Shift+Return newline · Tab instructions")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: escape).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 440, minHeight: 460)
        .task(id: model.session.id) {
            await Task.yield()
            focus = model.showingResult ? .result : .presets
        }
        .onChange(of: inputBusy) { _, busy in
            if !busy { focus = model.showingResult ? .result : .presets }
        }
        .onChange(of: model.isComplete) { _, complete in if complete { focus = .result } }
    }

    private func escape() {
        if model.isRunning { model.cancel(); model.restoreDraft() }
        else { onDismiss() }
    }
}

struct VoiceRewriteContainer: View {
    @ObservedObject var model: ClipboardRewriteModel
    @ObservedObject var voice: VoiceRewriteFlow
    let onDismiss: () -> Void
    let onRefresh: () -> Void
    let onAccept: () -> Void
    let onResize: (Bool) -> Void
    var onCopy: () -> Void = {}
    var onInsertAfter: () -> Void = {}
    private var compact: Bool { voice.isActive && !voice.expanded }

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(model.showingResult ? "Review rewrite" : "How should I rewrite it?").font(.headline)
                        Spacer()
                        Label("Local", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.sourceLabel).font(.caption).foregroundStyle(.secondary)
                    if let message = model.message ?? voice.notice {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    if model.showingResult {
                        TextEditor(text: $model.result).disabled(model.isRunning || model.isDelivering || voice.isBusy)
                            .accessibilityLabel("Rewrite result")
                        if model.isRunning { ProgressView("Rewriting…").controlSize(.small) }
                        RewriteResultTools(model: model, onCopy: onCopy, onInsertAfter: onInsertAfter)
                        HStack {
                            Button("Options") { voice.expand() }.keyboardShortcut("o", modifiers: .command)
                            Spacer()
                            Button(model.acceptTitle, action: onAccept)
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(!model.isComplete || model.isRunning || model.isDelivering)
                        }
                    } else {
                        if voice.stage == .listening {
                            ProgressView(value: Double(voice.level), total: 1).tint(.accentColor)
                            Label(voice.isRevision ? "Listening for revision instructions…" : "Listening for instructions…", systemImage: "mic.fill").font(.callout.weight(.semibold)).foregroundStyle(.red)
                        } else if voice.isBusy {
                            ProgressView(voice.sourcePending ? "Finishing your message…" : "Transcribing instructions…")
                                .controlSize(.small)
                        }
                        Text(model.instructions.isEmpty ? "Try “make it shorter and friendlier.”" : model.instructions)
                            .frame(maxWidth: .infinity, minHeight: 55, alignment: .topLeading)
                            .lineLimit(4).textSelection(.enabled)
                        Spacer(minLength: 0)
                        HStack {
                            Button("Options · Hyper+C") { voice.expand() }.keyboardShortcut("o", modifiers: .command)
                            Spacer()
                            Button("Rewrite") { voice.finish() }
                                .keyboardShortcut(.return, modifiers: [])
                                .disabled(voice.stage != .listening)
                        }
                    }
                    HStack {
                        Text(model.showingResult ? "⌘Enter accepts · Esc closes" : "Enter finishes instructions · Hyper+C opens options").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            if voice.sourcePending { onDismiss() }
                            else if voice.isBusy || model.isRunning { voice.cancelOperation() } else { onDismiss() }
                        }.keyboardShortcut(.cancelAction)
                    }
                }
                .padding(18).background(Color(nsColor: .windowBackgroundColor))
                .frame(minWidth: 440, minHeight: 250)
            } else {
                ClipboardRewriteView(model: model, onDismiss: onDismiss, onRefresh: onRefresh,
                    onAccept: onAccept,
                    title: "Rewrite " + model.session.kind.rawValue.capitalized, inputBusy: voice.isBusy,
                    voiceNotice: voice.isBusy ? "Finishing voice instructions…" : voice.notice,
                    allowsRefresh: !model.dictationCanPaste, onCopy: onCopy, onInsertAfter: onInsertAfter)
            }
        }
        .onChange(of: compact) { _, value in onResize(value) }
        .onChange(of: model.showingResult) { _, _ in onResize(compact) }
    }
}
