import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import LocalDictation

@Suite("Hotkey Enter policy")
@MainActor
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

    @Test("numeric-pad and Caps Lock metadata do not block Enter")
    func neutralMetadataRemainsSupported() throws {
        let coordinator = recordingCoordinator()
        let manager = manager(for: coordinator)
        let flags: CGEventFlags = [.maskNumericPad, .maskAlphaShift]
        let keyDown = try returnEvent(keyDown: true, flags: flags)

        #expect(manager.handle(type: .keyDown, event: keyDown) == nil)
        #expect(coordinator.phase == .finalizing)

        let keyUp = try returnEvent(keyDown: false, flags: flags)
        #expect(manager.handle(type: .keyUp, event: keyUp) == nil)
    }

    @Test("every consumed Hyper+D down also consumes its eventual D up")
    func hyperDConsumesLateKeyUp() throws {
        let coordinator = recordingCoordinator()
        let manager = manager(for: coordinator)

        let down = try dEvent(keyDown: true, flags: hyperFlags)
        #expect(manager.handle(type: .keyDown, event: down) == nil)
        #expect(coordinator.phase == .finalizing)

        let up = try dEvent(keyDown: false, flags: [])
        #expect(manager.handle(type: .keyUp, event: up) == nil)
        #expect(coordinator.phase == .finalizing)
    }

    @Test("modifier release handles the logical D up exactly once")
    func modifierReleaseDoesNotDuplicateHotkeyUp() throws {
        let coordinator = DictationCoordinator()
        var emittedEffects: [DictationCoordinatorEffect] = []
        let manager = HotkeyManager(
            coordinator: coordinator,
            profileMode: { .clean },
            effectHandler: { emittedEffects.append(contentsOf: $0) }
        )

        let down = try dEvent(keyDown: true, flags: hyperFlags)
        #expect(manager.handle(type: .keyDown, event: down) == nil)
        #expect(coordinator.session?.hotkeyIsDown == true)

        let modifiersReleased = try dEvent(keyDown: true, flags: [])
        #expect(manager.handle(type: .flagsChanged, event: modifiersReleased) != nil)
        #expect(coordinator.session?.hotkeyIsDown == false)
        #expect(coordinator.session?.toggleArmed == true)

        let up = try dEvent(keyDown: false, flags: [])
        #expect(manager.handle(type: .keyUp, event: up) == nil)
        #expect(coordinator.phase == .recording)
        #expect(emittedEffects.count == 1)
    }

    @Test("Hyper+D autorepeat is consumed without manufacturing a release")
    func hyperDAutorepeatIsIdempotent() throws {
        let coordinator = DictationCoordinator()
        let manager = manager(for: coordinator)

        let down = try dEvent(keyDown: true, flags: hyperFlags)
        #expect(manager.handle(type: .keyDown, event: down) == nil)

        let repeated = try dEvent(keyDown: true, flags: hyperFlags, autorepeat: true)
        #expect(manager.handle(type: .keyDown, event: repeated) == nil)
        #expect(coordinator.session?.hotkeyIsDown == true)
        #expect(coordinator.session?.toggleArmed == false)
    }

    @Test("synthetic paste events never trigger the typing interlock")
    func syntheticPasteEventsAreIgnored() throws {
        let coordinator = recordingCoordinator()
        let manager = manager(for: coordinator)
        let event = try keyEvent(
            keyCode: UInt16(kVK_ANSI_V),
            keyDown: true,
            flags: .maskCommand
        )
        event.setIntegerValueField(
            .eventSourceUserData,
            value: HotkeyManager.syntheticPasteEventUserData
        )

        #expect(manager.handle(type: .keyDown, event: event) != nil)
        #expect(coordinator.session?.interleavedTyping == false)
    }

    @Test("tap health policy re-enables once before rebuilding")
    func tapHealthPolicy() {
        #expect(HotkeyTapHealthPolicy.action(tapExists: false, tapEnabled: false) == .create)
        #expect(HotkeyTapHealthPolicy.action(tapExists: true, tapEnabled: true) == .keep)
        #expect(HotkeyTapHealthPolicy.action(tapExists: true, tapEnabled: false) == .reenable)
        #expect(
            HotkeyTapHealthPolicy.action(
                tapExists: true,
                tapEnabled: false,
                reenableSucceeded: true
            ) == .keep
        )
        #expect(
            HotkeyTapHealthPolicy.action(
                tapExists: true,
                tapEnabled: false,
                reenableSucceeded: false
            ) == .rebuild
        )
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
        try keyEvent(keyCode: UInt16(kVK_Return), keyDown: keyDown, flags: flags)
    }

    private func dEvent(
        keyDown: Bool,
        flags: CGEventFlags,
        autorepeat: Bool = false
    ) throws -> CGEvent {
        let event = try keyEvent(
            keyCode: UInt16(kVK_ANSI_D),
            keyDown: keyDown,
            flags: flags
        )
        event.setIntegerValueField(
            .keyboardEventAutorepeat,
            value: autorepeat ? 1 : 0
        )
        return event
    }

    private func keyEvent(
        keyCode: UInt16,
        keyDown: Bool,
        flags: CGEventFlags
    ) throws -> CGEvent {
        let event = try #require(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: keyDown
            )
        )
        event.flags = flags
        return event
    }

    private var hyperFlags: CGEventFlags {
        [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    }
}
