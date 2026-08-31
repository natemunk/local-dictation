import Foundation

enum DictationPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case recording
    case finalizing
    case polishing
    case previewing
    case pasting
    case failed

    var hasActiveSession: Bool { self != .idle }
}

enum DictationMode: String, Codable, CaseIterable, Sendable {
    case clean
    case literal
}

enum DeliveryIntent: String, Codable, Sendable {
    case insert
    case preview
}

enum FinishTrigger: String, Codable, Sendable {
    case hotkey
    case enter
    case menu
    case durationLimit
}

struct EnterModifiers: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let option = EnterModifiers(rawValue: 1 << 0)
    static let shift = EnterModifiers(rawValue: 1 << 1)
    static let command = EnterModifiers(rawValue: 1 << 2)
    static let control = EnterModifiers(rawValue: 1 << 3)
    static let function = EnterModifiers(rawValue: 1 << 4)
    static let other = EnterModifiers(rawValue: 1 << 5)

    private static let supportedFinishModifiers: EnterModifiers = [.option, .shift]

    var isSupportedFinishCombination: Bool {
        isSubset(of: Self.supportedFinishModifiers)
    }
}

struct DictationFinishRequest: Equatable, Sendable {
    let sessionID: UUID
    let mode: DictationMode
    let delivery: DeliveryIntent
    let trigger: FinishTrigger
}

enum DictationCoordinatorEffect: Equatable, Sendable {
    case startCapture(sessionID: UUID)
    case finish(DictationFinishRequest)
    case cancel(sessionID: UUID)
    case interleavedTypingChanged(Bool)
}

struct DictationEventResponse: Equatable, Sendable {
    var consumeKeyEvent: Bool
    var effects: [DictationCoordinatorEffect]

    static let passThrough = DictationEventResponse(consumeKeyEvent: false, effects: [])
    static let consume = DictationEventResponse(consumeKeyEvent: true, effects: [])
}

/// A deterministic state machine for global dictation controls.
///
/// The coordinator intentionally knows nothing about AppKit, audio, ASR, or UI.
/// Callers execute returned effects and explicitly report phase transitions.
final class DictationCoordinator {
    struct Session: Equatable, Sendable {
        let id: UUID
        let profileMode: DictationMode
        let firstHotkeyDownAt: TimeInterval
        var hotkeyIsDown: Bool
        var toggleArmed: Bool
        var interleavedTyping: Bool
    }

    private(set) var phase: DictationPhase = .idle
    private(set) var session: Session?
    private(set) var tapHoldThreshold: TimeInterval

    init(tapHoldThreshold: TimeInterval = 0.350) {
        self.tapHoldThreshold = tapHoldThreshold
    }

    func updateTapHoldThreshold(_ threshold: TimeInterval) {
        guard phase == .idle else { return }
        tapHoldThreshold = max(0, threshold)
    }

    @discardableResult
    func hotkeyDown(at timestamp: TimeInterval, profileMode: DictationMode) -> DictationEventResponse {
        switch phase {
        case .idle, .failed:
            let session = Session(
                id: UUID(),
                profileMode: profileMode,
                firstHotkeyDownAt: timestamp,
                hotkeyIsDown: true,
                toggleArmed: false,
                interleavedTyping: false
            )
            self.session = session
            phase = .recording
            return DictationEventResponse(
                consumeKeyEvent: true,
                effects: [.startCapture(sessionID: session.id)]
            )

        case .recording:
            guard var session else { return .consume }
            // Ignore key-repeat while the initiating chord is still held.
            guard !session.hotkeyIsDown else { return .consume }
            session.hotkeyIsDown = true
            self.session = session

            guard session.toggleArmed else { return .consume }
            return requestFinish(mode: profileMode, delivery: .insert, trigger: .hotkey)

        case .finalizing, .polishing, .previewing, .pasting:
            // Never allow the global chord to leak into the destination app.
            return .consume
        }
    }

    @discardableResult
    func hotkeyUp(at timestamp: TimeInterval, profileMode: DictationMode) -> DictationEventResponse {
        guard phase == .recording, var session, session.hotkeyIsDown else {
            return .consume
        }

        session.hotkeyIsDown = false
        let heldFor = max(0, timestamp - session.firstHotkeyDownAt)

        if !session.toggleArmed && heldFor > tapHoldThreshold {
            self.session = session
            return requestFinish(mode: profileMode, delivery: .insert, trigger: .hotkey)
        }

        session.toggleArmed = true
        self.session = session
        return .consume
    }

    @discardableResult
    func nonModifierKeyTyped() -> DictationEventResponse {
        guard phase == .recording, var session else { return .passThrough }
        guard !session.interleavedTyping else { return .passThrough }

        session.interleavedTyping = true
        self.session = session
        return DictationEventResponse(
            consumeKeyEvent: false,
            effects: [.interleavedTypingChanged(true)]
        )
    }

    @discardableResult
    func enterPressed(modifiers: EnterModifiers, profileMode: DictationMode) -> DictationEventResponse {
        guard phase.hasActiveSession, let session else { return .passThrough }
        guard !session.interleavedTyping else { return .passThrough }
        guard modifiers.isSupportedFinishCombination else { return .passThrough }

        // The preview editor owns Return so it can edit multiple paragraphs.
        if phase == .previewing { return .passThrough }

        // During finalization/polishing/paste, swallow repeats from the key that
        // already finished the recording without starting a second operation.
        guard phase == .recording else { return .consume }

        let mode: DictationMode = modifiers.contains(.option) ? .literal : profileMode
        let delivery: DeliveryIntent = modifiers.contains(.shift) ? .preview : .insert
        return requestFinish(mode: mode, delivery: delivery, trigger: .enter)
    }

    @discardableResult
    func escapePressed() -> DictationEventResponse {
        guard phase.hasActiveSession, let session else { return .passThrough }
        let id = session.id
        phase = .idle
        self.session = nil
        return DictationEventResponse(consumeKeyEvent: true, effects: [.cancel(sessionID: id)])
    }

    @discardableResult
    func finishFromMenu(mode: DictationMode? = nil, preview: Bool = false) -> DictationEventResponse {
        guard phase == .recording, let session else { return .passThrough }
        return requestFinish(
            mode: mode ?? session.profileMode,
            delivery: preview ? .preview : .insert,
            trigger: .menu
        )
    }

    @discardableResult
    func durationLimitReached(profileMode: DictationMode) -> DictationEventResponse {
        guard phase == .recording, session != nil else { return .passThrough }
        return requestFinish(
            mode: profileMode,
            delivery: .preview,
            trigger: .durationLimit
        )
    }

    func transition(to newPhase: DictationPhase) {
        switch (phase, newPhase) {
        case (.finalizing, .polishing),
             (.finalizing, .previewing),
             (.finalizing, .pasting),
             (.polishing, .previewing),
             (.polishing, .pasting),
             (.previewing, .pasting),
             (_, .failed):
            phase = newPhase
        default:
            assertionFailure("Invalid dictation transition: \(phase.rawValue) -> \(newPhase.rawValue)")
        }
    }

    func complete() {
        phase = .idle
        session = nil
    }

    private func requestFinish(
        mode: DictationMode,
        delivery: DeliveryIntent,
        trigger: FinishTrigger
    ) -> DictationEventResponse {
        guard phase == .recording, let session else { return .consume }
        phase = .finalizing
        let request = DictationFinishRequest(
            sessionID: session.id,
            mode: mode,
            delivery: delivery,
            trigger: trigger
        )
        return DictationEventResponse(consumeKeyEvent: true, effects: [.finish(request)])
    }
}
