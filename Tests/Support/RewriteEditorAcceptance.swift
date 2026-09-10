import AppKit
import Carbon.HIToolbox
import Darwin

private struct AcceptanceWriter: ClipboardWriting {
    func availabilityMessage() -> String? { nil }
    func rewrite(_ request: WritingRequest, onPartial: @escaping @Sendable (String) async -> Void) async throws -> String { request.source }
}
@MainActor
private final class NoMicrophoneRecorder: RewriteInstructionRecording {
    func start(onPartial: @escaping (String) -> Void, onLevel: @escaping (Float) -> Void, onFailure: @escaping () -> Void) throws {
        acceptanceIssue("Acceptance must not record the microphone")
        throw CancellationError()
    }
    func stop() async throws -> URL { throw CancellationError() }
    func cancel() {}
}

/// Explicit opt-in only. Operates exclusively on newly created synthetic TextEdit files.
@MainActor
struct SelectionEditorAcceptanceTests {
    func run() async throws {
        acceptanceExpect(AXIsProcessTrusted())
        guard AXIsProcessTrusted() else { return }
        _ = NSApplication.shared

        NSApp.setActivationPolicy(.accessory)

        let previousApp = NSWorkspace.shared.frontmostApplication
        let pb = NSPasteboard.general
        // Save formats in memory only. Never print, persist, or assert their content.
        let previousItems = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        var ownedCount = pb.changeCount
        var clipboardStillOwned = true
        defer {
            if clipboardStillOwned && pb.changeCount == ownedCount {
                pb.clearContents()
                let items = previousItems.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pb.writeObjects(items) }
            }
            previousApp?.activate()
        }
        for rich in [false, true] {
            fputs(rich ? "Checking rich text\n" : "Checking plain text\n", stderr)
            let original = "Opening 🐈 paragraph.\nDeadline Friday at 3 pm.\nClosing paragraph."
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Local-Dictation-Acceptance-" + UUID().uuidString + (rich ? ".rtf" : ".txt"))
            if rich {
                let text = NSAttributedString(string: original, attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
                try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: file)
            } else { try original.write(to: file, atomically: true, encoding: .utf8) }
            try script("tell application \"TextEdit\"\nopen POSIX file \"" + file.path + "\"\nactivate\nend tell")
            defer {
                try? script("tell application \"TextEdit\" to close document \"" + file.lastPathComponent + "\" saving no")
                try? FileManager.default.removeItem(at: file)
            }
            try await Task.sleep(for: .milliseconds(500))

            let app = try acceptanceRequire(NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.TextEdit" })
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            let windowValue = try acceptanceRequire(attribute(kAXFocusedWindowAttribute, axApp))
            let window = windowValue as! AXUIElement
            // Never inspect another user's document text.
            acceptanceExpect(attribute(kAXTitleAttribute, window) as? String == file.lastPathComponent)
            guard attribute(kAXTitleAttribute, window) as? String == file.lastPathComponent else { throw CancellationError() }
            let elementValue = try acceptanceRequire(attribute(kAXFocusedUIElementAttribute, axApp))
            let element = elementValue as! AXUIElement
            guard attribute(kAXValueAttribute, element) as? String == original else { acceptanceIssue("Synthetic fixture changed; aborting"); throw CancellationError() }
            let originalAttributes = rich ? try acceptanceRequire(prefixAttributes(element)) : nil
            let range = (original as NSString).range(of: "Deadline Friday at 3 pm.")
            try select(range, element)


            let model = ClipboardRewriteModel(writer: AcceptanceWriter(), isDictationBusy: { false }, copy: { _ in false })
            let flow = VoiceRewriteFlow(model: model, recorder: NoMicrophoneRecorder(), transcribe: { _ in throw CancellationError() })
            let controller = ClipboardRewriteWindowController(model: model, voice: flow, isDictationBusy: { false }, readClipboard: { acceptanceIssue("Selection test must not read clipboard text"); return nil })
            let inserter = TextInserter(privateClipboardMode: { true })
            var pasteCount = 0
            var rejectAfterPreflight = false
            controller.deliverSelection = { text, destination, checks in
                guard clipboardStillOwned, pb.changeCount == ownedCount else { clipboardStillOwned = false; throwIssue(); return .cancelled }
                if rejectAfterPreflight {
                    acceptanceExpect(await checks.preflight())
                    return .historyOnly(reason: "Synthetic failure after preflight")
                }
                let outcome = await inserter.insertText(text, destination: destination, reactivateDestination: true, insertionGuard: checks)
                if pb.changeCount != ownedCount {
                    switch outcome {
                    case .pasteEventSent, .clipboardOnly:
                        guard pb.string(forType: .string) == text else {
                            clipboardStillOwned = false; throwIssue(); return .cancelled
                        }
                        ownedCount = pb.changeCount
                    case .historyOnly, .cancelled:
                        // Do not adopt an external copy as our own and later restore over it.
                        clipboardStillOwned = false
                    }
                }
                if case .pasteEventSent = outcome { pasteCount += 1 }
                return outcome
            }
            controller.beginFromFrontmost(listen: false)

            do {
                try await settle { controller.isVisible && model.session.kind == .selection }
            } catch {
                // Only state and process IDs, never clipboard or field contents.
                fputs("Capture state kind=\(model.session.kind.rawValue) visible=\(controller.isVisible) front=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) expected=\(app.processIdentifier)\n", stderr)
                throw error
            }

            acceptanceExpect(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier)
            acceptanceExpect(controller.isKeyWindow)
            acceptanceExpect(model.source == "Deadline Friday at 3 pm.")
            acceptanceExpect(model.canReplaceSelection)
            model.reviewOriginal(); model.result = "Deadline Monday at 4 pm."
            if let preview = ProcessInfo.processInfo.environment["LD_EDITOR_PREVIEW"] {
                try await Task.sleep(for: .milliseconds(50))
                if let view = NSApp.windows.first(where: { $0.title.hasPrefix("Rewrite ·") })?.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: URL(fileURLWithPath: preview + (rich ? "-rich.png" : "-plain.png")))
                    }
                }
            }
            controller.acceptSelection()
            controller.acceptSelection() // Duplicate key delivery must not repeat insertion.
            try await settle { !model.isDelivering && pasteCount == 1 }
            try await Task.sleep(for: .milliseconds(150))
            let replaced = original.replacingOccurrences(of: "Deadline Friday at 3 pm.", with: "Deadline Monday at 4 pm.")
            try await settle { attribute(kAXValueAttribute, element) as? String == replaced }
            if let originalAttributes { acceptanceExpect(prefixAttributes(element) == originalAttributes) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                acceptanceIssue("Focus changed before Undo; aborting fixture")
                throw CancellationError()
            }
            postUndo()
            try await settle { attribute(kAXValueAttribute, element) as? String == original }

            try select(range, element)

            controller.beginFromFrontmost(listen: false)

            try await settle { controller.isVisible && model.canInsertAfterSelection }
            model.reviewOriginal(); model.result = "Additional 🐈 line."
            controller.acceptSelection(insertAfter: true)
            try await settle { !model.isDelivering && pasteCount == 2 }
            try await Task.sleep(for: .milliseconds(150))
            let inserted = original.replacingOccurrences(of: "Deadline Friday at 3 pm.", with: "Deadline Friday at 3 pm.\n\nAdditional 🐈 line.")
            try await settle { attribute(kAXValueAttribute, element) as? String == inserted }
            if let originalAttributes { acceptanceExpect(prefixAttributes(element) == originalAttributes) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                acceptanceIssue("Focus changed before Undo; aborting fixture")
                throw CancellationError()
            }
            postUndo()
            try await settle { attribute(kAXValueAttribute, element) as? String == original }

            // Failure after preflight must not collapse the original selection.
            try select(range, element)
            controller.beginFromFrontmost(listen: false)
            try await settle { controller.isVisible && model.canInsertAfterSelection }
            model.reviewOriginal(); model.result = "Must not move caret"
            let beforeFailure = pb.changeCount
            rejectAfterPreflight = true
            controller.acceptSelection(insertAfter: true)
            try await settle { !model.isDelivering }
            rejectAfterPreflight = false
            acceptanceExpect(pb.changeCount == beforeFailure && pasteCount == 2)
            let selectedValue = try acceptanceRequire(attribute(kAXSelectedTextRangeAttribute, element)) as! AXValue
            var preservedRange = CFRange()
            acceptanceExpect(AXValueGetValue(selectedValue, .cfRange, &preservedRange))
            acceptanceExpect(preservedRange.location == range.location && preservedRange.length == range.length)
            controller.dismiss()

            // Selection changes between review and acceptance: preflight must leave clipboard alone.
            try select(range, element)

            controller.beginFromFrontmost(listen: false)

            try await settle { controller.isVisible && model.canReplaceSelection }
            model.reviewOriginal(); model.result = "Do not insert"
            try select(NSRange(location: 0, length: 7), element)
            let before = pb.changeCount
            controller.acceptSelection()
            try await settle { !model.isDelivering }
            acceptanceExpect(pb.changeCount == before)
            acceptanceExpect(pasteCount == 2)
            acceptanceExpect(attribute(kAXValueAttribute, element) as? String == original)
            acceptanceExpect(controller.isVisible && model.isComplete)
            controller.dismiss()

            // Exercise real key routing after the result editor has taken focus.
            try select(range, element)
            controller.beginFromFrontmost(listen: false)
            try await settle { controller.isVisible && model.canReplaceSelection }
            try await Task.sleep(for: .milliseconds(100))
            postKey(CGKeyCode(kVK_DownArrow))
            try await settle { model.action == .concise }
            postKey(CGKeyCode(kVK_UpArrow))
            try await settle { model.action == .clean }
            model.action = .custom
            postKey(CGKeyCode(kVK_Return)) // Empty custom instructions focus their field.
            try await Task.sleep(for: .milliseconds(100))
            model.instructions = "Synthetic instruction"
            postKey(CGKeyCode(kVK_Return), flags: .maskShift)
            try await settle { model.instructions.contains("\n") }
            acceptanceExpect(!model.isRunning && !model.isComplete)
            postKey(CGKeyCode(kVK_Return))
            try await settle { model.isComplete }
            model.result = "Keyboard accepted."
            try await Task.sleep(for: .milliseconds(100))
            postKey(CGKeyCode(kVK_Return), flags: .maskCommand)
            try await settle { pasteCount == 3 && !model.isDelivering }
            let keyboardResult = original.replacingOccurrences(of: "Deadline Friday at 3 pm.", with: "Keyboard accepted.")
            try await settle { attribute(kAXValueAttribute, element) as? String == keyboardResult }
            postUndo()
            try await settle { attribute(kAXValueAttribute, element) as? String == original }
        }
    }

    private func settle(file: StaticString = #fileID, line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        acceptanceIssue("Timed out waiting for synthetic editor acceptance at \(file):\(line)")
        throw CancellationError()
    }
    private func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func prefixAttributes(_ element: AXUIElement) -> NSDictionary? {
        var range = CFRange(location: 0, length: 7)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                        parameter, &value) == .success,
              let text = value as? NSAttributedString, text.length == 7 else { return nil }
        return text.attributes(at: 0, effectiveRange: nil) as NSDictionary
    }
    private func select(_ range: NSRange, _ element: AXUIElement) throws {
        var r = CFRange(location: range.location, length: range.length)
        let value = try acceptanceRequire(AXValueCreate(.cfRange, &r))
        acceptanceExpect(AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success)
    }
    private func postUndo() { postKey(CGKeyCode(kVK_ANSI_Z), flags: .maskCommand) }
    private func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
    }
    private func script(_ code: String) throws {
        var error: NSDictionary?
        NSAppleScript(source: code)?.executeAndReturnError(&error)
        if error != nil { acceptanceIssue("Could not prepare or close the disposable TextEdit document"); throw CancellationError() }
    }
}

@MainActor private func throwIssue() { acceptanceIssue("Clipboard changed externally; acceptance aborted") }

@MainActor private var acceptanceFailures = 0
@MainActor private func acceptanceExpect(_ condition: Bool, file: StaticString = #fileID, line: UInt = #line) {
    if !condition { acceptanceFailures += 1; fputs("Acceptance failed at \(file):\(line)\n", stderr) }
}
@MainActor private func acceptanceRequire<T>(_ value: T?) throws -> T {
    guard let value else { acceptanceIssue("Required synthetic fixture value missing"); throw CancellationError() }
    return value
}
@MainActor private func acceptanceIssue(_ message: String) {
    acceptanceFailures += 1
    fputs(message + "\n", stderr)
}
@MainActor private final class AcceptanceAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await SelectionEditorAcceptanceTests().run() }
            catch { acceptanceIssue("Editor acceptance did not complete") }
            fputs(acceptanceFailures == 0 ? "EDITOR ACCEPTANCE PASSED\n" : "EDITOR ACCEPTANCE FAILED\n", stderr)
            Darwin.exit(acceptanceFailures == 0 ? 0 : 1)
        }
    }
}
@main private struct AcceptanceMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AcceptanceAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
