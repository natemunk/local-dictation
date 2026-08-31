import AppKit
import Carbon.HIToolbox

enum GlobalKeyMonitorError: LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
        switch self {
        case .eventTapUnavailable:
            "Local Dictation could not monitor Hyper+D. Enable Input Monitoring and Accessibility in System Settings."
        }
    }
}

/// A single session event tap owns the dictation chord and the session-scoped
/// Enter/Escape safety rules. It never synthesizes Return.
final class HotkeyManager {
    typealias EffectHandler = ([DictationCoordinatorEffect]) -> Void

    private let coordinator: DictationCoordinator
    private let profileMode: () -> DictationMode
    private let effectHandler: EffectHandler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppressedKeyUps = Set<UInt16>()

    init(
        coordinator: DictationCoordinator,
        profileMode: @escaping () -> DictationMode,
        effectHandler: @escaping EffectHandler
    ) {
        self.coordinator = coordinator
        self.profileMode = profileMode
        self.effectHandler = effectHandler
    }

    deinit {
        stop()
    }

    var isMonitoring: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    func start(promptForPermission: Bool = true) throws {
        guard eventTap == nil else { return }
        if promptForPermission, !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: opaqueSelf
        ) else {
            AppLogger.hotkey.error(
                "Unable to create event tap; Input Monitoring=\(CGPreflightListenEventAccess(), privacy: .public), Accessibility=\(AXIsProcessTrusted(), privacy: .public)"
            )
            throw GlobalKeyMonitorError.eventTapUnavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.eventTap = eventTap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        AppLogger.hotkey.info(
            "Hyper+D event tap started; Input Monitoring=\(CGPreflightListenEventAccess(), privacy: .public), Accessibility=\(AXIsProcessTrusted(), privacy: .public)"
        )
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        suppressedKeyUps.removeAll()
        AppLogger.hotkey.info("Hyper+D event tap stopped")
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            AppLogger.hotkey.warning("Hyper+D event tap was disabled by the system; re-enabling it")
            if let eventTap = manager.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        return manager.handle(type: type, event: event)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isDKey = keyCode == UInt16(kVK_ANSI_D)
        let hyperD = isDKey && hasHyperModifiers(event.flags)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let response: DictationEventResponse

        switch type {
        case .keyDown where hyperD:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            response = isRepeat
                ? .consume
                : coordinator.hotkeyDown(at: timestamp, profileMode: profileMode())

        // Recognize the initiating D key-up even if the user released one or
        // more Hyper modifiers first.
        case .keyUp where isDKey && coordinator.session?.hotkeyIsDown == true:
            response = coordinator.hotkeyUp(at: timestamp, profileMode: profileMode())

        case .keyUp where suppressedKeyUps.remove(keyCode) != nil:
            response = .consume

        case .keyDown where coordinator.phase.hasActiveSession:
            if keyCode == UInt16(kVK_Escape) {
                response = coordinator.escapePressed()
            } else if keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                response = coordinator.enterPressed(
                    modifiers: enterModifiers(from: event.flags),
                    profileMode: profileMode()
                )
            } else {
                response = coordinator.nonModifierKeyTyped()
            }

        default:
            response = .passThrough
        }

        if !response.effects.isEmpty {
            DispatchQueue.main.async { [effectHandler] in effectHandler(response.effects) }
        }
        if type == .keyDown,
           response.consumeKeyEvent,
           keyCode == UInt16(kVK_Return)
               || keyCode == UInt16(kVK_ANSI_KeypadEnter)
               || keyCode == UInt16(kVK_Escape)
        {
            suppressedKeyUps.insert(keyCode)
        }
        return response.consumeKeyEvent ? nil : Unmanaged.passUnretained(event)
    }

    private func hasHyperModifiers(_ flags: CGEventFlags) -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return flags.intersection(relevant) == relevant
    }

    private func enterModifiers(from flags: CGEventFlags) -> EnterModifiers {
        var result: EnterModifiers = []
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }

        // CGEvent's low 16 bits identify left/right device keys and event
        // metadata. Bits 16 and above are the device-independent modifier and
        // special-key plane. Numeric-pad is key-origin metadata, so ignore it;
        // fail closed for every other unclassified bit, including Caps Lock,
        // Help, and future flags.
        let classifiedFlags: CGEventFlags = [
            .maskAlternate,
            .maskShift,
            .maskCommand,
            .maskControl,
            .maskSecondaryFn,
            .maskNumericPad,
        ]
        let deviceIndependentFlags = flags.rawValue & ~UInt64(0xFFFF)
        if deviceIndependentFlags & ~classifiedFlags.rawValue != 0 {
            result.insert(.other)
        }
        return result
    }
}
