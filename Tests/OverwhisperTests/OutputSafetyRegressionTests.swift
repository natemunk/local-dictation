import AppKit
import Foundation
import Testing
@testable import LocalDictation

// NSPasteboard is process-global and its server can reject concurrent named
// pasteboard mutations even when each test uses a unique name.
@Suite("Output safety regressions", .serialized)
struct OutputSafetyRegressionTests {
    @Test("destination capture rejects missing and non-editable focused elements")
    @MainActor
    func captureFailsClosed() {
        let missing = DictationDestination.captureFrontmost(candidateProvider: { nil })
        let nonEditable = DictationDestination.captureFrontmost(candidateProvider: {
            candidate(focusedElementIsEditable: false)
        })

        #expect(missing == nil)
        #expect(nonEditable == nil)
    }

    @Test("frontmost-app fallback accepts an unclassified field only when explicitly enabled")
    @MainActor
    func captureAllowsGuardedFrontmostFallback() async throws {
        var validated = false
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(
                    focusedElementIsEditable: false,
                    allowsFrontmostApplicationFallback: true,
                    reactivateAndValidate: {
                        validated = true
                        return true
                    }
                )
            })
        )

        #expect(await destination.reactivateAndValidate())
        #expect(validated)
    }

    @Test("guarded frontmost fallback posts Command-V and preserves the prior clipboard")
    @MainActor
    func guardedFrontmostFallbackPastes() async throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("Previous clipboard", forType: .string)
        var pasteWasAttempted = false
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(
                    focusedElementIsEditable: false,
                    allowsFrontmostApplicationFallback: true
                )
            })
        )
        let inserter = TextInserter(
            pasteboard: pasteboard,
            accessibilityPermission: { true },
            pasteSimulator: {
                pasteWasAttempted = true
                return true
            },
            delay: { _ in }
        )

        #expect(await inserter.insertText("Transcript", destination: destination) == .pasted)
        #expect(pasteWasAttempted)
        #expect(pasteboard.string(forType: .string) == "Previous clipboard")
    }

    @Test("missing destination leaves the transcript on the clipboard without pasting")
    @MainActor
    func missingDestinationUsesClipboardOnly() async {
        let pasteboard = makePasteboard()
        var pasteWasAttempted = false
        let inserter = TextInserter(
            pasteboard: pasteboard,
            accessibilityPermission: { true },
            pasteSimulator: {
                pasteWasAttempted = true
                return true
            },
            delay: { _ in }
        )

        let outcome = await inserter.insertText("Transcript", destination: nil)

        #expect(
            outcome == .clipboardOnly(reason: "No focused editable destination was captured")
        )
        #expect(pasteboard.string(forType: .string) == "Transcript")
        #expect(!pasteWasAttempted)
    }

    @Test("failed destination validation leaves the transcript on the clipboard")
    @MainActor
    func invalidDestinationUsesClipboardOnly() async throws {
        let pasteboard = makePasteboard()
        var pasteWasAttempted = false
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(
                    focusedElementIsEditable: true,
                    reactivateAndValidate: { false }
                )
            })
        )
        let inserter = TextInserter(
            pasteboard: pasteboard,
            accessibilityPermission: { true },
            pasteSimulator: {
                pasteWasAttempted = true
                return true
            },
            delay: { _ in }
        )

        let outcome = await inserter.insertText("Transcript", destination: destination)

        #expect(
            outcome == .clipboardOnly(reason: "The original destination field is no longer focused")
        )
        #expect(pasteboard.string(forType: .string) == "Transcript")
        #expect(!pasteWasAttempted)
    }

    @Test("focus loss before Command-V leaves the transcript clipboard-only")
    @MainActor
    func focusLossBeforePasteUsesClipboardOnly() async throws {
        let pasteboard = makePasteboard()
        var pasteWasAttempted = false
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(
                    focusedElementIsEditable: true,
                    reactivateAndValidate: { true },
                    remainsFocusedAndEditable: { false }
                )
            })
        )
        let inserter = TextInserter(
            pasteboard: pasteboard,
            accessibilityPermission: { true },
            pasteSimulator: {
                pasteWasAttempted = true
                return true
            },
            delay: { _ in }
        )

        let outcome = await inserter.insertText("Transcript", destination: destination)

        #expect(
            outcome == .clipboardOnly(reason: "The original destination field is no longer focused")
        )
        #expect(pasteboard.string(forType: .string) == "Transcript")
        #expect(!pasteWasAttempted)
    }

    @Test("synthetic paste failure retains the transcript for recovery")
    @MainActor
    func pasteFailureRetainsTranscript() async throws {
        let pasteboard = makePasteboard()
        let richData = Data("{\\rtf1 Previous rich clipboard}".utf8)
        let originalItem = NSPasteboardItem()
        originalItem.setString("Previous rich clipboard", forType: .string)
        originalItem.setData(richData, forType: .rtf)
        #expect(pasteboard.writeObjects([originalItem]))

        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(focusedElementIsEditable: true)
            })
        )
        let inserter = TextInserter(
            pasteboard: pasteboard,
            accessibilityPermission: { true },
            pasteSimulator: { false },
            delay: { _ in }
        )

        let outcome = await inserter.insertText("Transcript", destination: destination)

        #expect(
            outcome == .clipboardOnly(reason: "Could not create a synthetic paste event")
        )
        let retainedItem = try #require(pasteboard.pasteboardItems?.first)
        #expect(retainedItem.string(forType: .string) == "Transcript")
        #expect(retainedItem.data(forType: .rtf) == nil)
    }

    @Test("successful paste restores every unchanged clipboard representation")
    @MainActor
    func successfulPasteRestoresRichClipboard() async throws {
        let pasteboard = makePasteboard()
        let richData = Data("{\\rtf1 Previous rich clipboard}".utf8)
        let originalItem = NSPasteboardItem()
        originalItem.setString("Previous rich clipboard", forType: .string)
        originalItem.setData(richData, forType: .rtf)
        #expect(pasteboard.writeObjects([originalItem]))
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(focusedElementIsEditable: true)
            })
        )
        let inserter = TextInserter(
            pasteboard: pasteboard,
            accessibilityPermission: { true },
            pasteSimulator: { true },
            delay: { _ in }
        )

        #expect(await inserter.insertText("Transcript", destination: destination) == .pasted)
        let restoredItem = try #require(pasteboard.pasteboardItems?.first)
        #expect(restoredItem.string(forType: .string) == "Previous rich clipboard")
        #expect(restoredItem.data(forType: .rtf) == richData)
    }

    @Test("pre-paste cancellation restores every unchanged clipboard representation")
    @MainActor
    func cancellationRestoresRichClipboard() async throws {
        let pasteboard = makePasteboard()
        let richData = Data("{\\rtf1 Previous rich clipboard}".utf8)
        let originalItem = NSPasteboardItem()
        originalItem.setString("Previous rich clipboard", forType: .string)
        originalItem.setData(richData, forType: .rtf)
        #expect(pasteboard.writeObjects([originalItem]))
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(focusedElementIsEditable: true)
            })
        )
        let inserter = TextInserter(
            pasteboard: pasteboard,
            accessibilityPermission: { true },
            pasteSimulator: { true },
            delay: { _ in throw CancellationError() }
        )

        #expect(await inserter.insertText("Transcript", destination: destination) == .cancelled)
        let restoredItem = try #require(pasteboard.pasteboardItems?.first)
        #expect(restoredItem.string(forType: .string) == "Previous rich clipboard")
        #expect(restoredItem.data(forType: .rtf) == richData)
    }

    @Test("synthetic paste failure does not overwrite a concurrent clipboard change")
    @MainActor
    func pasteFailurePreservesConcurrentClipboardChange() async throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("Previous clipboard", forType: .string)
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(focusedElementIsEditable: true)
            })
        )
        let inserter = TextInserter(
            pasteboard: pasteboard,
            accessibilityPermission: { true },
            pasteSimulator: {
                pasteboard.clearContents()
                pasteboard.setString("Concurrent clipboard", forType: .string)
                return false
            },
            delay: { _ in }
        )

        let outcome = await inserter.insertText("Transcript", destination: destination)

        #expect(
            outcome == .clipboardOnly(reason: "Could not create a synthetic paste event")
        )
        #expect(pasteboard.string(forType: .string) == "Concurrent clipboard")
    }

    @Test("clipboard changes before Command-V are never pasted")
    @MainActor
    func clipboardChangeBeforePasteStopsInsertion() async throws {
        let pasteboard = makePasteboard()
        var pasteWasAttempted = false
        var delayCount = 0
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(focusedElementIsEditable: true)
            })
        )
        let inserter = TextInserter(
            pasteboard: pasteboard,
            accessibilityPermission: { true },
            pasteSimulator: {
                pasteWasAttempted = true
                return true
            },
            delay: { _ in
                delayCount += 1
                if delayCount == 1 {
                    pasteboard.clearContents()
                    pasteboard.setString("Concurrent clipboard", forType: .string)
                }
            }
        )

        let outcome = await inserter.insertText("Transcript", destination: destination)

        #expect(outcome == .clipboardOnly(reason: "The clipboard changed before paste"))
        #expect(pasteboard.string(forType: .string) == "Concurrent clipboard")
        #expect(!pasteWasAttempted)
    }

    @MainActor
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        return pasteboard
    }

    @MainActor
    private func candidate(
        focusedElementIsEditable: Bool,
        allowsFrontmostApplicationFallback: Bool = false,
        reactivateAndValidate: @escaping @MainActor () async -> Bool = { true },
        remainsFocusedAndEditable: @escaping @MainActor () -> Bool = { true }
    ) -> DictationDestination.CaptureCandidate {
        DictationDestination.CaptureCandidate(
            processIdentifier: 42,
            bundleIdentifier: "com.example.Editor",
            applicationName: "Editor",
            role: "AXTextArea",
            subrole: nil,
            focusedElementIsEditable: focusedElementIsEditable,
            allowsFrontmostApplicationFallback: allowsFrontmostApplicationFallback,
            reactivateAndValidate: reactivateAndValidate,
            remainsFocusedAndEditable: remainsFocusedAndEditable
        )
    }
}
