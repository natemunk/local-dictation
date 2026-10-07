import AppKit
import Foundation

/// The only value a correction prompt can emit after the user explicitly
/// confirms it. The prompt does not read history, the clipboard, or any
/// configuration, and it does not persist the mapping.
struct VocabularyCorrectionMapping: Equatable, Sendable {
    let spokenForm: String
    let writtenForm: String
}

/// Pure state for the correction prompt. Keeping selection handling separate
/// from AppKit makes the phrase-selection behaviour easy to test and keeps
/// the window controller free of persistence concerns.
struct VocabularyCorrectionDraft: Equatable, Sendable {
    let rawText: String
    private(set) var spokenForm: String
    var writtenForm: String

    init(rawText: String, spokenForm: String = "", writtenForm: String = "") {
        self.rawText = rawText
        self.spokenForm = spokenForm
        self.writtenForm = writtenForm
    }

    mutating func setSpokenForm(_ value: String) {
        spokenForm = value
    }

    /// Copies the selected transcript phrase into the heard field. Empty or
    /// invalid selections leave the current draft untouched.
    mutating func applySelection(_ selectedText: String) {
        let phrase = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        spokenForm = phrase
    }

    /// Returns the mapping only when both values are valid for the personal
    /// vocabulary format. Persistence remains the responsibility of the
    /// PersonalVocabularyEditor.
    func validatedMapping() throws -> VocabularyCorrectionMapping {
        let spoken = spokenForm.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !spoken.isEmpty else {
            throw PersonalVocabularyEditorError.emptySpokenForm
        }
        guard !written.isEmpty else {
            throw PersonalVocabularyEditorError.emptyWrittenForm
        }
        guard !spoken.contains(where: \.isNewline),
              !written.contains(where: \.isNewline)
        else {
            throw PersonalVocabularyEditorError.multilineValue
        }

        return VocabularyCorrectionMapping(spokenForm: spoken, writtenForm: written)
    }
}

/// A modal, selectable transcript prompt for adding a personal vocabulary
/// correction. The controller emits one callback only after the user presses
/// Add Correction; cancel and window-close perform no callback and no writes.
@MainActor
final class VocabularyCorrectionWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private let onConfirm: (VocabularyCorrectionMapping) -> Void
    private let onCancel: () -> Void
    private var draft: VocabularyCorrectionDraft
    private var didFinish = false
    private var isRunningModal = false

    private let transcriptView = NSTextView()
    private let spokenField = NSTextField()
    private let writtenField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let confirmButton = NSButton(title: "Add Correction", target: nil, action: nil)
    private var window: NSWindow?

    init(
        rawText: String,
        onConfirm: @escaping (VocabularyCorrectionMapping) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.draft = VocabularyCorrectionDraft(rawText: rawText)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        super.init()
    }

    /// Presents the prompt as an application-modal window. The returned
    /// controller must be retained by callers using show(); runModal()
    /// retains itself for the duration of the synchronous modal call.
    func runModal() -> NSApplication.ModalResponse {
        isRunningModal = true
        show()
        guard let window else { return .abort }
        let response = NSApp.runModal(for: window)
        isRunningModal = false
        window.close()
        self.window = nil
        return response
    }

    /// Presents the prompt without entering a modal event loop. The callback
    /// is invoked only after explicit confirmation.
    func show() {
        if window == nil {
            window = makeWindow()
        }
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(spokenField)
    }

    func windowWillClose(_ notification: Notification) {
        finish(cancelled: true)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let range = transcriptView.selectedRange()
        let text = transcriptView.string as NSString
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              range.location <= text.length,
              range.length <= text.length - range.location
        else { return }
        let selected = text.substring(with: range)
        draft.applySelection(selected)
        spokenField.stringValue = draft.spokenForm
        clearValidationError()
        updateConfirmButton()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as AnyObject? === spokenField {
            draft.setSpokenForm(spokenField.stringValue)
        } else if notification.object as AnyObject? === writtenField {
            draft.writtenForm = writtenField.stringValue
        }
        clearValidationError()
        updateConfirmButton()
    }

    @objc private func confirm() {
        do {
            let mapping = try draft.validatedMapping()
            finish(cancelled: false, mapping: mapping)
        } catch let error as LocalizedError {
            errorLabel.stringValue = error.errorDescription ?? "Enter a valid one-line correction."
            errorLabel.isHidden = false
            updateConfirmButton()
        } catch {
            errorLabel.stringValue = "Enter a valid one-line correction."
            errorLabel.isHidden = false
            updateConfirmButton()
        }
    }

    @objc private func cancel() {
        finish(cancelled: true)
    }

    private func finish(cancelled: Bool, mapping: VocabularyCorrectionMapping? = nil) {
        guard !didFinish else { return }
        didFinish = true

        if isRunningModal, let window {
            NSApp.stopModal(withCode: cancelled ? .abort : .OK)
            window.orderOut(nil)
        } else {
            // windowWillClose can call this method while AppKit is already
            // closing the window. Ordering it out avoids recursively sending
            // close() from that delegate callback.
            window?.orderOut(nil)
        }

        if let mapping {
            onConfirm(mapping)
        } else if cancelled {
            onCancel()
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add Personal Vocabulary Correction"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = makeContentView()
        window.defaultButtonCell = confirmButton.cell as? NSButtonCell
        return window
    }

    func makeContentView() -> NSView {
        let content = NSView()

        let heading = NSTextField(labelWithString: "Select the phrase Local Dictation heard")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        transcriptView.string = draft.rawText
        transcriptView.isEditable = false
        transcriptView.isSelectable = true
        transcriptView.isVerticallyResizable = true
        transcriptView.isHorizontallyResizable = false
        transcriptView.autoresizingMask = [.width]
        transcriptView.textContainer?.widthTracksTextView = true
        transcriptView.delegate = self
        transcriptView.font = .systemFont(ofSize: NSFont.systemFontSize)
        transcriptView.textContainerInset = NSSize(width: 8, height: 8)
        transcriptView.drawsBackground = true
        transcriptView.backgroundColor = .textBackgroundColor

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = transcriptView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let instruction = NSTextField(labelWithString: "You can also edit the heard phrase directly below.")
        instruction.textColor = .secondaryLabelColor

        spokenField.placeholderString = "What it heard"
        spokenField.delegate = self
        spokenField.translatesAutoresizingMaskIntoConstraints = false

        writtenField.placeholderString = "What it should write"
        writtenField.delegate = self
        writtenField.translatesAutoresizingMaskIntoConstraints = false

        let spokenLabel = NSTextField(labelWithString: "Heard")
        spokenLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let writtenLabel = NSTextField(labelWithString: "Correction")
        writtenLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2

        confirmButton.target = self
        confirmButton.action = #selector(confirm)
        confirmButton.keyEquivalent = "\r"
        confirmButton.bezelStyle = .rounded

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [cancelButton, confirmButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            heading,
            scrollView,
            instruction,
            spokenLabel,
            spokenField,
            writtenLabel,
            writtenField,
            errorLabel,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 130),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 190),
            spokenField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            writtenField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])

        updateConfirmButton()
        return content
    }

    private func updateConfirmButton() {
        // Keep the button disabled for obvious invalid drafts, while the
        // authoritative editor still validates again before writing.
        confirmButton.isEnabled = (try? draft.validatedMapping()) != nil
    }

    private func clearValidationError() {
        errorLabel.stringValue = ""
        errorLabel.isHidden = true
    }
}

/// Convenience API for the existing synchronous menu action. Integration can
/// replace its current NSAlert body with:
///
///     guard let mapping = VocabularyCorrectionPrompt.runModal(rawText: entry.rawText) else { return }
///     // pass mapping.spokenForm and mapping.writtenForm to the editor
enum VocabularyCorrectionPrompt {
    @MainActor
    static func runModal(rawText: String) -> VocabularyCorrectionMapping? {
        var mapping: VocabularyCorrectionMapping?
        let controller = VocabularyCorrectionWindowController(
            rawText: rawText,
            onConfirm: { mapping = $0 }
        )
        _ = controller.runModal()
        return mapping
    }
}
