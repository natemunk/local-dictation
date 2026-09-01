import AppKit
import Foundation
import Testing
@testable import LocalDictation

// NSPasteboard is process-global and its server can reject concurrent named
// pasteboard mutations even when each test uses a unique name.
@Suite("Output safety regressions", .serialized)
struct OutputSafetyRegressionTests {
    @Test("destination capture requires a secure field or a concrete AX focus token")
    @MainActor
    func captureFailsClosed() {
        let missing = DictationDestination.captureFrontmost(candidateProvider: { nil })
        let noToken = DictationDestination.captureFrontmost(candidateProvider: {
            candidate(
                focusTokenAvailable: false,
                focusedElementIsEditable: false,
                allowsFocusTokenFallback: true
            )
        })
        let unapprovedToken = DictationDestination.captureFrontmost(candidateProvider: {
            candidate(
                focusTokenAvailable: true,
                focusedElementIsEditable: false,
                allowsFocusTokenFallback: false
            )
        })

        #expect(missing == nil)
        #expect(noToken == nil)
        #expect(unapprovedToken == nil)
    }

    @Test("exact editable and allowlisted focus-token tiers remain distinct")
    @MainActor
    func insertionTiers() throws {
        let exact = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(focusedElementIsEditable: true)
            })
        )
        let allowlisted = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(
                    focusedElementIsEditable: false,
                    allowsFocusTokenFallback: true
                )
            })
        )

        #expect(exact.insertionTier == .exactEditableElement)
        #expect(allowlisted.insertionTier == .allowlistedFocusToken)
    }

    @Test("tier-two product allowlist is explicit and rejects adjacent apps")
    @MainActor
    func focusTokenAllowlist() {
        #expect(
            DictationDestination.isApprovedFocusTokenFallback(
                bundleIdentifier: "com.tinyspeck.slackmacgap"
            )
        )
        #expect(
            DictationDestination.isApprovedFocusTokenFallback(
                bundleIdentifier: "com.google.Chrome"
            )
        )
        #expect(
            !DictationDestination.isApprovedFocusTokenFallback(
                bundleIdentifier: "com.example.UnreviewedEditor"
            )
        )
    }

    @Test("secure roles and protected content are detected conservatively")
    @MainActor
    func secureClassification() {
        #expect(
            DictationDestination.classifiesSecureField(
                role: "AXTextField",
                subrole: "AXSecureTextField",
                protectedContent: false
            )
        )
        #expect(
            DictationDestination.classifiesSecureField(
                role: "AXTextField",
                subrole: nil,
                protectedContent: true
            )
        )
        #expect(
            !DictationDestination.classifiesSecureField(
                role: "AXTextArea",
                subrole: nil,
                protectedContent: false
            )
        )
    }

    @Test("secure history repaste changes neither clipboard nor destination")
    @MainActor
    func secureRepasteIsHistoryOnly() async throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("Existing clipboard", forType: .string)
        var pasteWasAttempted = false
        let secure = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(
                    focusedElementIsEditable: false,
                    focusedElementIsSecure: true,
                    validateForInsertion: { _ in
                        Issue.record("Secure destination should never be validated for insertion")
                        return true
                    }
                )
            })
        )
        let inserter = makeInserter(
            pasteboard: pasteboard,
            pasteSimulator: {
                pasteWasAttempted = true
                return true
            }
        )

        let outcome = await inserter.insertText("Secret", destination: secure)

        #expect(
            outcome == .historyOnly(
                reason: "Secure fields cannot receive dictation or history paste"
            )
        )
        #expect(pasteboard.string(forType: .string) == "Existing clipboard")
        #expect(!pasteWasAttempted)
    }

    @Test("terminal classification covers native terminals and requires VS Code evidence")
    @MainActor
    func terminalClassification() {
        #expect(
            DictationDestination.classifiesTerminal(
                bundleIdentifier: "com.apple.Terminal",
                role: nil,
                subrole: nil,
                identifier: nil,
                description: nil
            )
        )
        #expect(
            DictationDestination.classifiesTerminal(
                bundleIdentifier: "com.microsoft.VSCode",
                role: "AXTextArea",
                subrole: nil,
                identifier: "workbench.panel.terminal",
                description: nil
            )
        )
        #expect(
            !DictationDestination.classifiesTerminal(
                bundleIdentifier: "com.microsoft.VSCode",
                role: "AXTextArea",
                subrole: nil,
                identifier: "editor",
                description: "Source editor"
            )
        )
    }

    @Test("terminal automatic output contains no line-break or repeated whitespace")
    func terminalLineBreakCollapse() {
        #expect(
            TerminalOutputSafety.collapseLineBreaks("first\nsecond\r\n  third\tvalue")
                == "first second third value"
        )
    }

    @Test("successful paste reports only that the event was sent and keeps transcript")
    @MainActor
    func successfulPasteKeepsTranscript() async throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("Previous clipboard", forType: .string)
        var pasteWasAttempted = false
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(focusedElementIsEditable: true)
            })
        )
        let inserter = makeInserter(
            pasteboard: pasteboard,
            pasteSimulator: {
                pasteWasAttempted = true
                return true
            }
        )

        let outcome = await inserter.insertText("Transcript", destination: destination)

        #expect(outcome == .pasteEventSent)
        #expect(pasteWasAttempted)
        #expect(pasteboard.string(forType: .string) == "Transcript")
    }

    @Test("missing destination leaves a verified ordinary clipboard value")
    @MainActor
    func missingDestinationUsesClipboardOnly() async {
        let pasteboard = makePasteboard()
        var pasteWasAttempted = false
        let inserter = makeInserter(
            pasteboard: pasteboard,
            pasteSimulator: {
                pasteWasAttempted = true
                return true
            }
        )

        let outcome = await inserter.insertText("Transcript", destination: nil)

        #expect(
            outcome == .clipboardOnly(reason: "No focused editable destination was captured")
        )
        #expect(pasteboard.string(forType: .string) == "Transcript")
        #expect(!pasteWasAttempted)
    }

    @Test("changed focus leaves the transcript on clipboard without posting paste")
    @MainActor
    func invalidDestinationUsesClipboardOnly() async throws {
        let pasteboard = makePasteboard()
        var pasteWasAttempted = false
        var receivedReactivation = true
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(
                    focusedElementIsEditable: true,
                    validateForInsertion: { reactivate in
                        receivedReactivation = reactivate
                        return false
                    }
                )
            })
        )
        let inserter = makeInserter(
            pasteboard: pasteboard,
            pasteSimulator: {
                pasteWasAttempted = true
                return true
            }
        )

        let outcome = await inserter.insertText("Transcript", destination: destination)

        #expect(
            outcome == .clipboardOnly(reason: "The original destination field is no longer focused")
        )
        #expect(!receivedReactivation)
        #expect(pasteboard.string(forType: .string) == "Transcript")
        #expect(!pasteWasAttempted)
    }

    @Test("preview delivery may request bounded destination reactivation")
    @MainActor
    func previewCanReactivate() async throws {
        let pasteboard = makePasteboard()
        var receivedReactivation = false
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(
                    focusedElementIsEditable: true,
                    validateForInsertion: { reactivate in
                        receivedReactivation = reactivate
                        return true
                    }
                )
            })
        )
        let inserter = makeInserter(pasteboard: pasteboard)

        #expect(
            await inserter.insertText(
                "Transcript",
                destination: destination,
                reactivateDestination: true
            ) == .pasteEventSent
        )
        #expect(receivedReactivation)
    }

    @Test("focus loss after validation leaves transcript clipboard-only")
    @MainActor
    func focusLossBeforePasteUsesClipboardOnly() async throws {
        let pasteboard = makePasteboard()
        var pasteWasAttempted = false
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(
                    focusedElementIsEditable: true,
                    validateForInsertion: { _ in true },
                    remainsValidForInsertion: { false }
                )
            })
        )
        let inserter = makeInserter(
            pasteboard: pasteboard,
            pasteSimulator: {
                pasteWasAttempted = true
                return true
            }
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
        let inserter = makeInserter(
            pasteboard: pasteboard,
            pasteSimulator: { false }
        )

        let outcome = await inserter.insertText("Transcript", destination: destination)

        #expect(
            outcome == .clipboardOnly(reason: "Could not create a synthetic paste event")
        )
        let retainedItem = try #require(pasteboard.pasteboardItems?.first)
        #expect(retainedItem.string(forType: .string) == "Transcript")
        #expect(retainedItem.data(forType: .rtf) == nil)
    }

    @Test("concurrent clipboard changes are never overwritten or pasted")
    @MainActor
    func clipboardChangeBeforePasteStopsInsertion() async throws {
        let pasteboard = makePasteboard()
        var pasteWasAttempted = false
        let destination = try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                candidate(focusedElementIsEditable: true)
            })
        )
        let inserter = makeInserter(
            pasteboard: pasteboard,
            pasteSimulator: {
                pasteWasAttempted = true
                return true
            },
            yieldBeforeValidation: {
                pasteboard.clearContents()
                pasteboard.setString("Concurrent clipboard", forType: .string)
            }
        )

        let outcome = await inserter.insertText("Transcript", destination: destination)

        #expect(outcome == .historyOnly(reason: "The clipboard changed before paste"))
        #expect(pasteboard.string(forType: .string) == "Concurrent clipboard")
        #expect(!pasteWasAttempted)
    }

    @Test("private clipboard mode adds concealed and transient markers")
    @MainActor
    func privateClipboardMarkers() throws {
        let pasteboard = makePasteboard()
        let inserter = makeInserter(
            pasteboard: pasteboard,
            privateClipboardMode: { true }
        )

        #expect(inserter.copyOnly("Transcript"))
        let item = try #require(pasteboard.pasteboardItems?.first)
        #expect(item.string(forType: .string) == "Transcript")
        #expect(item.types.contains(TextInserter.concealedPasteboardType))
        #expect(item.types.contains(TextInserter.transientPasteboardType))
    }

    @Test("Paste Again operations execute serially across suspension")
    @MainActor
    func pasteAgainIsSerialized() async {
        let queue = SerializedPasteAgainQueue()
        var events: [String] = []
        var releaseFirst: CheckedContinuation<Void, Never>?

        _ = queue.enqueue {
            events.append("first-start")
            await withCheckedContinuation { continuation in
                releaseFirst = continuation
            }
            events.append("first-end")
        }
        while releaseFirst == nil { await Task.yield() }

        let second = queue.enqueue {
            events.append("second")
        }
        await Task.yield()
        #expect(events == ["first-start"])

        releaseFirst?.resume()
        await second.value
        #expect(events == ["first-start", "first-end", "second"])
    }

    @MainActor
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        return pasteboard
    }

    @MainActor
    private func makeInserter(
        pasteboard: NSPasteboard,
        accessibilityPermission: @escaping @MainActor () -> Bool = { true },
        pasteSimulator: @escaping @MainActor () -> Bool = { true },
        privateClipboardMode: @escaping @MainActor () -> Bool = { false },
        yieldBeforeValidation: @escaping @MainActor () async -> Void = {}
    ) -> TextInserter {
        TextInserter(
            pasteboard: pasteboard,
            accessibilityPermission: accessibilityPermission,
            pasteSimulator: pasteSimulator,
            privateClipboardMode: privateClipboardMode,
            yieldBeforeValidation: yieldBeforeValidation
        )
    }

    @MainActor
    private func candidate(
        bundleIdentifier: String = "com.example.Editor",
        focusTokenAvailable: Bool = true,
        focusedElementIsEditable: Bool,
        focusedElementIsSecure: Bool = false,
        focusedElementIsTerminal: Bool = false,
        allowsFocusTokenFallback: Bool = false,
        validateForInsertion: @escaping @MainActor (Bool) async -> Bool = { _ in true },
        remainsValidForInsertion: @escaping @MainActor () -> Bool = { true }
    ) -> DictationDestination.CaptureCandidate {
        DictationDestination.CaptureCandidate(
            processIdentifier: 42,
            bundleIdentifier: bundleIdentifier,
            applicationName: "Editor",
            role: "AXTextArea",
            subrole: nil,
            focusTokenAvailable: focusTokenAvailable,
            focusedElementIsEditable: focusedElementIsEditable,
            focusedElementIsSecure: focusedElementIsSecure,
            focusedElementIsTerminal: focusedElementIsTerminal,
            allowsFocusTokenFallback: allowsFocusTokenFallback,
            validateForInsertion: validateForInsertion,
            remainsValidForInsertion: remainsValidForInsertion
        )
    }
}
