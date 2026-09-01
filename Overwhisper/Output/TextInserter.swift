import AppKit
import Carbon.HIToolbox

enum InsertionOutcome: Equatable, Sendable {
    /// Command+V was posted after every available safety check. This does not
    /// claim that the destination accepted or rendered the paste.
    case pasteEventSent
    /// The transcript is verified as the current clipboard value.
    case clipboardOnly(reason: String)
    /// No paste was posted and the transcript is not claimed to be retained on
    /// the clipboard. Normal dictations remain recoverable from local history.
    case historyOnly(reason: String)
    case cancelled
}

@MainActor
final class TextInserter {
    static let concealedPasteboardType = NSPasteboard.PasteboardType(
        "org.nspasteboard.ConcealedType"
    )
    static let transientPasteboardType = NSPasteboard.PasteboardType(
        "org.nspasteboard.TransientType"
    )

    private let pasteboard: NSPasteboard
    private let accessibilityPermission: @MainActor () -> Bool
    private let pasteSimulator: @MainActor () -> Bool
    private let privateClipboardMode: @MainActor () -> Bool
    private let yieldBeforeValidation: @MainActor () async -> Void

    init(privateClipboardMode: @escaping @MainActor () -> Bool = { false }) {
        pasteboard = .general
        accessibilityPermission = { AXIsProcessTrusted() }
        pasteSimulator = { TextInserter.postSyntheticPaste() }
        self.privateClipboardMode = privateClipboardMode
        yieldBeforeValidation = { await Task.yield() }
    }

    init(
        pasteboard: NSPasteboard,
        accessibilityPermission: @escaping @MainActor () -> Bool,
        pasteSimulator: @escaping @MainActor () -> Bool,
        privateClipboardMode: @escaping @MainActor () -> Bool = { false },
        yieldBeforeValidation: @escaping @MainActor () async -> Void = { await Task.yield() }
    ) {
        self.pasteboard = pasteboard
        self.accessibilityPermission = accessibilityPermission
        self.pasteSimulator = pasteSimulator
        self.privateClipboardMode = privateClipboardMode
        self.yieldBeforeValidation = yieldBeforeValidation
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Writes the transcript first, then immediately revalidates destination,
    /// cancellation, and pasteboard ownership before posting Command+V. The
    /// transcript remains on the clipboard after every normal attempt.
    func insertText(
        _ text: String,
        destination: DictationDestination?,
        reactivateDestination: Bool = false
    ) async -> InsertionOutcome {
        guard !Task.isCancelled else { return .cancelled }

        // Repasting history into a secure field must not touch the clipboard.
        guard destination?.isSecureField != true else {
            return .historyOnly(reason: "Secure fields cannot receive dictation or history paste")
        }

        guard let transcriptChangeCount = writeTranscript(text) else {
            return .historyOnly(reason: "Could not write the transcript to the clipboard")
        }

        guard accessibilityPermission() else {
            return clipboardOutcome(
                text: text,
                expectedChangeCount: transcriptChangeCount,
                reason: "Accessibility permission is not granted"
            )
        }

        guard let destination else {
            return clipboardOutcome(
                text: text,
                expectedChangeCount: transcriptChangeCount,
                reason: "No focused editable destination was captured"
            )
        }

        await yieldBeforeValidation()
        guard !Task.isCancelled else { return .cancelled }
        guard clipboardContainsTranscript(text, changeCount: transcriptChangeCount) else {
            return .historyOnly(reason: "The clipboard changed before paste")
        }

        let destinationIsValid = await destination.validateForInsertion(
            reactivateIfNeeded: reactivateDestination
        )
        guard !Task.isCancelled else { return .cancelled }
        guard destinationIsValid, destination.remainsValidForInsertion() else {
            return clipboardOutcome(
                text: text,
                expectedChangeCount: transcriptChangeCount,
                reason: "The original destination field is no longer focused"
            )
        }
        guard clipboardContainsTranscript(text, changeCount: transcriptChangeCount) else {
            return .historyOnly(reason: "The clipboard changed before paste")
        }
        guard pasteSimulator() else {
            return clipboardOutcome(
                text: text,
                expectedChangeCount: transcriptChangeCount,
                reason: "Could not create a synthetic paste event"
            )
        }

        return .pasteEventSent
    }

    @discardableResult
    func copyOnly(_ text: String) -> Bool {
        writeTranscript(text) != nil
    }

    private func writeTranscript(_ text: String) -> Int? {
        pasteboard.clearContents()
        let wrote: Bool
        if privateClipboardMode() {
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string) else { return nil }
            item.setData(Data(), forType: Self.concealedPasteboardType)
            item.setData(Data(), forType: Self.transientPasteboardType)
            wrote = pasteboard.writeObjects([item])
        } else {
            wrote = pasteboard.setString(text, forType: .string)
        }
        guard wrote else { return nil }
        return pasteboard.changeCount
    }

    private func clipboardContainsTranscript(_ text: String, changeCount: Int) -> Bool {
        pasteboard.changeCount == changeCount
            && pasteboard.string(forType: .string) == text
    }

    private func clipboardOutcome(
        text: String,
        expectedChangeCount: Int,
        reason: String
    ) -> InsertionOutcome {
        clipboardContainsTranscript(text, changeCount: expectedChangeCount)
            ? .clipboardOnly(reason: reason)
            : .historyOnly(reason: reason)
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
