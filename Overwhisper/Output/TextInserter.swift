import AppKit
import Carbon.HIToolbox

enum InsertionOutcome: Equatable, Sendable {
    case pasted
    case clipboardOnly(reason: String)
    case cancelled
}

@MainActor
final class TextInserter {
    private let pasteboard: NSPasteboard
    private let accessibilityPermission: @MainActor () -> Bool
    private let pasteSimulator: @MainActor () -> Bool
    private let delay: @MainActor (Duration) async throws -> Void

    init() {
        pasteboard = .general
        accessibilityPermission = { AXIsProcessTrusted() }
        pasteSimulator = { TextInserter.postSyntheticPaste() }
        delay = { duration in
            try await Task.sleep(for: duration)
        }
    }

    init(
        pasteboard: NSPasteboard,
        accessibilityPermission: @escaping @MainActor () -> Bool,
        pasteSimulator: @escaping @MainActor () -> Bool,
        delay: @escaping @MainActor (Duration) async throws -> Void
    ) {
        self.pasteboard = pasteboard
        self.accessibilityPermission = accessibilityPermission
        self.pasteSimulator = pasteSimulator
        self.delay = delay
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Uses the audited Overwhisper clipboard + synthetic Command+V path.
    /// The destination field is validated after preview focus changes; direct
    /// AX value mutation is deliberately not attempted in v1 cutover.
    func insertText(_ text: String, destination: DictationDestination?) async -> InsertionOutcome {
        guard !Task.isCancelled else { return .cancelled }

        guard accessibilityPermission() else {
            retainOnClipboard(text, pasteboard: pasteboard)
            return .clipboardOnly(reason: "Accessibility permission is not granted")
        }

        guard let destination else {
            retainOnClipboard(text, pasteboard: pasteboard)
            return .clipboardOnly(reason: "No focused editable destination was captured")
        }

        let destinationIsValid = await destination.reactivateAndValidate()
        guard !Task.isCancelled else { return .cancelled }
        guard destinationIsValid else {
            retainOnClipboard(text, pasteboard: pasteboard)
            return .clipboardOnly(reason: "The original destination field is no longer focused")
        }

        let savedItems = Self.snapshot(pasteboard)
        pasteboard.clearContents()
        let wroteTranscript = pasteboard.setString(text, forType: .string)
        let transcriptChangeCount = pasteboard.changeCount
        guard wroteTranscript else {
            restore(savedItems, ifUnchangedFrom: transcriptChangeCount, on: pasteboard)
            return .clipboardOnly(reason: "Could not write the transcript to the clipboard")
        }

        do {
            try await delay(.milliseconds(75))
            try Task.checkCancellation()
        } catch {
            restore(savedItems, ifUnchangedFrom: transcriptChangeCount, on: pasteboard)
            return .cancelled
        }

        guard destination.remainsFocusedAndEditable() else {
            return .clipboardOnly(reason: "The original destination field is no longer focused")
        }
        guard pasteboard.changeCount == transcriptChangeCount else {
            return .clipboardOnly(reason: "The clipboard changed before paste")
        }
        guard pasteSimulator() else {
            return .clipboardOnly(reason: "Could not create a synthetic paste event")
        }

        // Give rich editors time to read all pasteboard representations.
        try? await delay(.milliseconds(350))
        restore(savedItems, ifUnchangedFrom: transcriptChangeCount, on: pasteboard)
        return .pasted
    }

    func copyOnly(_ text: String) {
        retainOnClipboard(text, pasteboard: pasteboard)
    }

    private func retainOnClipboard(_ text: String, pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func restore(
        _ items: [NSPasteboardItem],
        ifUnchangedFrom changeCount: Int,
        on pasteboard: NSPasteboard
    ) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func postSyntheticPaste() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false
              )
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.setIntegerValueField(
            .eventSourceUserData,
            value: HotkeyManager.syntheticPasteEventUserData
        )
        keyUp.setIntegerValueField(
            .eventSourceUserData,
            value: HotkeyManager.syntheticPasteEventUserData
        )
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
