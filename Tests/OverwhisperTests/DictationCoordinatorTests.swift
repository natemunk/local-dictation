import Foundation
import Testing
@testable import LocalDictation

@Suite("Dictation coordinator")
struct DictationCoordinatorTests {
    @Test("capture starts on key-down and a quick tap arms toggle mode")
    func quickTapStartsImmediately() {
        let coordinator = DictationCoordinator(tapHoldThreshold: 0.350)

        let down = coordinator.hotkeyDown(at: 10, profileMode: .clean)
        #expect(coordinator.phase == .recording)
        #expect(down.consumeKeyEvent)
        #expect(down.effects.count == 1)

        let up = coordinator.hotkeyUp(at: 10.349, profileMode: .clean)
        #expect(up.consumeKeyEvent)
        #expect(up.effects.isEmpty)
        #expect(coordinator.phase == .recording)
        #expect(coordinator.session?.toggleArmed == true)
    }

    @Test("a hold longer than the threshold finishes on release")
    func holdBecomesPushToTalk() {
        let coordinator = DictationCoordinator(tapHoldThreshold: 0.350)
        _ = coordinator.hotkeyDown(at: 1, profileMode: .literal)

        let response = coordinator.hotkeyUp(at: 1.351, profileMode: .literal)

        #expect(coordinator.phase == .finalizing)
        guard case let .finish(request) = response.effects.first else {
            Issue.record("Expected finish effect")
            return
        }
        #expect(request.mode == .literal)
        #expect(request.delivery == .insert)
        #expect(request.trigger == .hotkey)
    }

    @Test("the second Hyper+D key-down uses the destination profile at finish")
    func secondHotkeyDownFinishes() {
        let coordinator = DictationCoordinator()
        _ = coordinator.hotkeyDown(at: 1, profileMode: .clean)
        _ = coordinator.hotkeyUp(at: 1.1, profileMode: .clean)

        let response = coordinator.hotkeyDown(at: 2, profileMode: .literal)

        #expect(coordinator.phase == .finalizing)
        guard case let .finish(request) = response.effects.first else {
            Issue.record("Expected finish effect")
            return
        }
        // The user may switch applications while recording, so the profile
        // supplied at finish intentionally wins over the profile at start.
        #expect(request.mode == .literal)
        #expect(request.trigger == .hotkey)
    }

    @Test("typing interlock leaves every Enter variant with the foreground app")
    func typingInterlockIsPermanentForSession() {
        let coordinator = DictationCoordinator()
        _ = coordinator.hotkeyDown(at: 1, profileMode: .clean)
        _ = coordinator.hotkeyUp(at: 1.1, profileMode: .clean)

        let typing = coordinator.nonModifierKeyTyped()
        #expect(!typing.consumeKeyEvent)
        #expect(coordinator.session?.interleavedTyping == true)

        for modifiers: EnterModifiers in [[], .option, .shift, [.option, .shift], .command, .control] {
            let enter = coordinator.enterPressed(modifiers: modifiers, profileMode: .clean)
            #expect(!enter.consumeKeyEvent)
            #expect(enter.effects.isEmpty)
            #expect(coordinator.phase == .recording)
        }

        // No inactivity-based re-arm exists; Hyper+D remains the finisher.
        let finish = coordinator.hotkeyDown(at: 500, profileMode: .clean)
        #expect(finish.consumeKeyEvent)
        #expect(coordinator.phase == .finalizing)
    }

    @Test("Enter variants choose mode and preview intent")
    func enterVariants() {
        let cases: [(EnterModifiers, DictationMode, DeliveryIntent)] = [
            ([], .clean, .insert),
            (.option, .literal, .insert),
            (.shift, .clean, .preview),
            ([.option, .shift], .literal, .preview),
        ]

        for (modifiers, expectedMode, expectedDelivery) in cases {
            let coordinator = DictationCoordinator()
            _ = coordinator.hotkeyDown(at: 1, profileMode: .clean)
            _ = coordinator.hotkeyUp(at: 1.1, profileMode: .clean)

            let response = coordinator.enterPressed(modifiers: modifiers, profileMode: .clean)
            #expect(response.consumeKeyEvent)
            guard case let .finish(request) = response.effects.first else {
                Issue.record("Expected finish effect")
                continue
            }
            #expect(request.mode == expectedMode)
            #expect(request.delivery == expectedDelivery)
            #expect(request.trigger == .enter)
        }
    }

    @Test("repeated Enter is swallowed while finalizing")
    func repeatedEnterIsSwallowed() {
        let coordinator = DictationCoordinator()
        _ = coordinator.hotkeyDown(at: 1, profileMode: .clean)
        _ = coordinator.hotkeyUp(at: 1.1, profileMode: .clean)
        _ = coordinator.enterPressed(modifiers: [], profileMode: .clean)

        let repeatPress = coordinator.enterPressed(modifiers: [], profileMode: .clean)
        #expect(repeatPress.consumeKeyEvent)
        #expect(repeatPress.effects.isEmpty)
    }

    @Test("Escape cancels recording and in-flight phases")
    func escapeCancels() {
        let coordinator = DictationCoordinator()
        let start = coordinator.hotkeyDown(at: 1, profileMode: .clean)
        guard case let .startCapture(sessionID) = start.effects.first else {
            Issue.record("Expected capture effect")
            return
        }

        let response = coordinator.escapePressed()
        #expect(response.consumeKeyEvent)
        #expect(response.effects == [.cancel(sessionID: sessionID)])
        #expect(coordinator.phase == .idle)
        #expect(coordinator.session == nil)
    }

    @Test("the 15-minute cap always routes to preview")
    func durationCapUsesPreview() {
        let coordinator = DictationCoordinator()
        _ = coordinator.hotkeyDown(at: 1, profileMode: .clean)

        let response = coordinator.durationLimitReached(profileMode: .clean)
        guard case let .finish(request) = response.effects.first else {
            Issue.record("Expected finish effect")
            return
        }
        #expect(request.delivery == .preview)
        #expect(request.trigger == .durationLimit)
    }
}
