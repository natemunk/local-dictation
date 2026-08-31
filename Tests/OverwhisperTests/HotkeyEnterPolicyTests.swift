import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import LocalDictation

@Suite("Hotkey Enter policy")
struct HotkeyEnterPolicyTests {
    @Test("approved Enter variants finish and suppress key-up without an event tap")
    func approvedVariantsFinishAndSuppressKeyUp() throws {
        let variants: [CGEventFlags] = [
            [],
            .maskAlternate,
            .maskShift,
            [.maskAlternate, .maskShift],
        ]

        for flags in variants {
            let coordinator = recordingCoordinator()
            let manager = manager(for: coordinator)
            let keyDown = try returnEvent(keyDown: true, flags: flags)

            #expect(manager.handle(type: .keyDown, event: keyDown) == nil)
            #expect(coordinator.phase == .finalizing)

            let keyUp = try returnEvent(keyDown: false, flags: flags)
            #expect(manager.handle(type: .keyUp, event: keyUp) == nil)
        }
    }

    @Test("unsupported Return modifiers pass through without changing coordinator state")
    func unsupportedModifiersPassThrough() throws {
        let variants: [CGEventFlags] = [
            .maskCommand,
            .maskControl,
            .maskSecondaryFn,
            .maskAlphaShift,
            .maskHelp,
            [.maskAlternate, .maskCommand],
            [.maskShift, .maskControl],
            [.maskAlternate, .maskShift, .maskSecondaryFn],
            CGEventFlags(rawValue: 0x0100_0000),
        ]

        for flags in variants {
            let coordinator = recordingCoordinator()
            let originalSession = coordinator.session
            let manager = manager(for: coordinator)
            let keyDown = try returnEvent(keyDown: true, flags: flags)

            #expect(manager.handle(type: .keyDown, event: keyDown) != nil)
            #expect(coordinator.phase == .recording)
            #expect(coordinator.session == originalSession)

            let keyUp = try returnEvent(keyDown: false, flags: flags)
            #expect(manager.handle(type: .keyUp, event: keyUp) != nil)
            #expect(coordinator.phase == .recording)
            #expect(coordinator.session == originalSession)
        }
    }

    @Test("unsupported Return stays pass-through after finalization starts")
    func unsupportedModifierPassesThroughWhileFinalizing() throws {
        let coordinator = recordingCoordinator()
        _ = coordinator.enterPressed(modifiers: [], profileMode: .clean)
        let originalSession = coordinator.session
        let manager = manager(for: coordinator)
        let keyDown = try returnEvent(keyDown: true, flags: .maskCommand)

        #expect(manager.handle(type: .keyDown, event: keyDown) != nil)
        #expect(coordinator.phase == .finalizing)
        #expect(coordinator.session == originalSession)

        let keyUp = try returnEvent(keyDown: false, flags: .maskCommand)
        #expect(manager.handle(type: .keyUp, event: keyUp) != nil)
        #expect(coordinator.phase == .finalizing)
        #expect(coordinator.session == originalSession)
    }

    @Test("numeric-pad origin does not count as an unsupported modifier")
    func numericPadOriginRemainsSupported() throws {
        let coordinator = recordingCoordinator()
        let manager = manager(for: coordinator)
        let keyDown = try returnEvent(keyDown: true, flags: .maskNumericPad)

        #expect(manager.handle(type: .keyDown, event: keyDown) == nil)
        #expect(coordinator.phase == .finalizing)

        let keyUp = try returnEvent(keyDown: false, flags: .maskNumericPad)
        #expect(manager.handle(type: .keyUp, event: keyUp) == nil)
    }

    private func recordingCoordinator() -> DictationCoordinator {
        let coordinator = DictationCoordinator()
        _ = coordinator.hotkeyDown(at: 1, profileMode: .clean)
        _ = coordinator.hotkeyUp(at: 1.1, profileMode: .clean)
        return coordinator
    }

    private func manager(for coordinator: DictationCoordinator) -> HotkeyManager {
        HotkeyManager(
            coordinator: coordinator,
            profileMode: { .clean },
            effectHandler: { _ in }
        )
    }

    private func returnEvent(keyDown: Bool, flags: CGEventFlags) throws -> CGEvent {
        let event = try #require(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_Return),
                keyDown: keyDown
            )
        )
        event.flags = flags
        return event
    }
}
