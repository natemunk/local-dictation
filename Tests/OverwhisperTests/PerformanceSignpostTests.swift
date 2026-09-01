import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import LocalDictation

@Suite("Privacy-safe performance signposts", .serialized)
struct PerformanceSignpostTests {
    @Test("event catalog is fixed and contains no request payload")
    func fixedEventCatalog() {
        #expect(
            DictationPerformanceEvent.allCases.map(\.rawValue) == [
                "hotkey",
                "overlay",
                "capture-ready",
                "stop",
                "ASR",
                "cleanup",
                "clipboard-write",
                "paste-event-post",
                "completion",
            ]
        )
    }

    @Test("recognized hotkey emits once and autorepeat emits nothing")
    @MainActor
    func hotkeyEmission() throws {
        let coordinator = DictationCoordinator()
        var events: [DictationPerformanceEvent] = []
        var correlationIDs: [UInt64] = []
        let manager = HotkeyManager(
            coordinator: coordinator,
            profileMode: { .clean },
            effectHandler: { _ in },
            performanceSignpost: {
                events.append($0)
                correlationIDs.append($1)
            }
        )

        let keyDown = try dEvent(keyDown: true)
        #expect(manager.handle(type: .keyDown, event: keyDown) == nil)
        #expect(events == [.hotkey])
        #expect(correlationIDs.count == 1)
        #expect(correlationIDs.first == coordinator.session?.token.generation)

        let repeatedKeyDown = try dEvent(keyDown: true, autorepeat: true)
        #expect(manager.handle(type: .keyDown, event: repeatedKeyDown) == nil)
        #expect(events == [.hotkey])

        let keyUp = try dEvent(keyDown: false)
        #expect(manager.handle(type: .keyUp, event: keyUp) == nil)
        let finishKeyDown = try dEvent(keyDown: true)
        #expect(manager.handle(type: .keyDown, event: finishKeyDown) == nil)
        #expect(events == [.hotkey])
    }

    @Test("TextInserter emits only successful clipboard and paste milestones")
    @MainActor
    func insertionEmission() async throws {
        let successfulPasteboard = makePasteboard()
        var successfulEvents: [DictationPerformanceEvent] = []
        let successfulInserter = makeInserter(
            pasteboard: successfulPasteboard,
            pasteSimulator: { true },
            performanceSignpost: { event, _ in successfulEvents.append(event) }
        )
        let destination = try editableDestination()

        let outcome = await successfulInserter.insertText(
            "Private transcript",
            destination: destination,
            performanceCorrelationID: 42
        )

        #expect(outcome == .pasteEventSent)
        #expect(successfulEvents == [.clipboardWrite, .pasteEventPost])

        #expect(successfulInserter.copyOnly("Uncorrelated copy"))
        #expect(successfulEvents == [.clipboardWrite, .pasteEventPost])

        let failedPasteboard = makePasteboard()
        var failedEvents: [DictationPerformanceEvent] = []
        let failedInserter = makeInserter(
            pasteboard: failedPasteboard,
            pasteSimulator: { false },
            performanceSignpost: { event, _ in failedEvents.append(event) }
        )

        _ = await failedInserter.insertText(
            "Another private transcript",
            destination: destination,
            performanceCorrelationID: 43
        )

        #expect(failedEvents == [.clipboardWrite])
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
        pasteSimulator: @escaping @MainActor () -> Bool,
        performanceSignpost: @escaping @MainActor (DictationPerformanceEvent, UInt64) -> Void
    ) -> TextInserter {
        TextInserter(
            pasteboard: pasteboard,
            accessibilityPermission: { true },
            pasteSimulator: pasteSimulator,
            performanceSignpost: performanceSignpost
        )
    }

    @MainActor
    private func editableDestination() throws -> DictationDestination {
        try #require(
            DictationDestination.captureFrontmost(candidateProvider: {
                DictationDestination.CaptureCandidate(
                    processIdentifier: 42,
                    bundleIdentifier: "com.example.Editor",
                    applicationName: "Editor",
                    role: "AXTextArea",
                    subrole: nil,
                    focusTokenAvailable: true,
                    focusedElementIsEditable: true,
                    focusedElementIsSecure: false,
                    focusedElementIsTerminal: false,
                    allowsFocusTokenFallback: false,
                    validateForInsertion: { _ in true },
                    remainsValidForInsertion: { true }
                )
            })
        )
    }

    @MainActor
    private func dEvent(keyDown: Bool, autorepeat: Bool = false) throws -> CGEvent {
        let event = try #require(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_ANSI_D),
                keyDown: keyDown
            )
        )
        event.flags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        event.setIntegerValueField(
            .keyboardEventAutorepeat,
            value: autorepeat ? 1 : 0
        )
        return event
    }
}
