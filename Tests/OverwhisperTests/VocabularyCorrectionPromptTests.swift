import Foundation
import AppKit
import Testing
@testable import LocalDictation

@Suite("Vocabulary correction prompt")
struct VocabularyCorrectionPromptTests {
    @Test @MainActor func nativeSelectionUsesUTF16RangesWithoutChangingTranscript() throws {
        let raw = "Try 👩🏽‍💻 OpenRouter"
        let controller = VocabularyCorrectionWindowController(rawText: raw, onConfirm: { _ in })
        let content = controller.makeContentView()
        content.frame = NSRect(x: 0, y: 0, width: 560, height: 500)
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = descendants(content)
        let text = try #require(views.compactMap { $0 as? NSTextView }.first)
        let heard = try #require(views.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "What it heard" })
        #expect(text.isSelectable)
        #expect(!text.isEditable)
        #expect(text.textContainer?.widthTracksTextView == true)
        text.setSelectedRange((raw as NSString).range(of: "OpenRouter"))
        controller.textViewDidChangeSelection(.init(name: NSTextView.didChangeSelectionNotification, object: text))
        #expect(heard.stringValue == "OpenRouter")
        #expect(text.string == raw)
    }

    @Test("selection becomes the heard phrase and trims selection edges")
    func selectionFillsHeardPhrase() throws {
        var draft = VocabularyCorrectionDraft(rawText: "Please open router in Ghostty")
        draft.applySelection("  open router  ")
        draft.writtenForm = "OpenRouter"

        #expect(draft.spokenForm == "open router")
        #expect(try draft.validatedMapping() == VocabularyCorrectionMapping(
            spokenForm: "open router",
            writtenForm: "OpenRouter"
        ))
    }

    @Test("empty selection never erases an existing heard phrase")
    func emptySelectionPreservesHeardPhrase() {
        var draft = VocabularyCorrectionDraft(rawText: "OpenRouter")
        draft.applySelection("OpenRouter")
        draft.applySelection("")
        draft.applySelection("  \n  ")
        #expect(draft.spokenForm == "OpenRouter")
    }

    @Test("validation rejects empty and multiline mappings before confirmation")
    func rejectsInvalidDrafts() {
        let emptySpoken = VocabularyCorrectionDraft(rawText: "text", writtenForm: "value")
        #expect(throws: PersonalVocabularyEditorError.emptySpokenForm) {
            _ = try emptySpoken.validatedMapping()
        }

        let emptyWritten = VocabularyCorrectionDraft(rawText: "text", spokenForm: "heard")
        #expect(throws: PersonalVocabularyEditorError.emptyWrittenForm) {
            _ = try emptyWritten.validatedMapping()
        }

        let multiline = VocabularyCorrectionDraft(
            rawText: "text",
            spokenForm: "heard",
            writtenForm: "line one\nline two"
        )
        #expect(throws: PersonalVocabularyEditorError.multilineValue) {
            _ = try multiline.validatedMapping()
        }
    }

    @Test("raw transcript remains display-only until explicit confirmation")
    func draftDoesNotPersistOrRewriteTranscript() throws {
        var draft = VocabularyCorrectionDraft(rawText: "I said OpenRouter")
        draft.applySelection("OpenRouter")
        draft.writtenForm = "OpenRouter AI"
        let mapping = try draft.validatedMapping()

        #expect(draft.rawText == "I said OpenRouter")
        #expect(mapping.spokenForm == "OpenRouter")
        #expect(mapping.writtenForm == "OpenRouter AI")
    }
}
