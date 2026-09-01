import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum GlobalKeyMonitorError: Error, LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
        switch self {
        case .eventTapUnavailable:
            "Local Dictation could not monitor Hyper+D. Enable Input Monitoring and Accessibility in System Settings."
        }
    }
}

enum HotkeyTapRecoveryAction: Equatable, Sendable {
    case keep
    case reenable
    case rebuild
    case create
}

enum HotkeyTapHealthPolicy {
    static func action(
        tapExists: Bool,
        tapEnabled: Bool,
        reenableSucceeded: Bool? = nil
    ) -> HotkeyTapRecoveryAction {
        guard tapExists else { return .create }
        guard !tapEnabled else { return .keep }
        guard let reenableSucceeded else { return .reenable }
        return reenableSucceeded ? .keep : .rebuild
    }
}

@MainActor
final class HotkeyManager {
    static let syntheticPasteEventUserData: Int64 = 0x4C44_5041_5354_4501

    private struct PendingKeyUp {
        let expiresAt: TimeInterval
    }

    private let coordinator: DictationCoordinator
    private let profileMode: () -> DictationMode
    private let effectHandler: ([DictationCoordinatorEffect]) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingKeyUps: [UInt16: PendingKeyUp] = [:]
    private var physicalDDown = false
    private var logicalDReleaseHandled = false

    private(set) var tapDisableCount = 0
    private(set) var tapRebuildCount = 0
    private(set) var lastTapDisableReason: String?

    private static let keyUpSuppressionLifetime: TimeInterval = 2

    init(
        coordinator: DictationCoordinator,
        profileMode: @escaping () -> DictationMode,
        effectHandler: @escaping ([DictationCoordinatorEffect]) -> Void
    ) {
        self.coordinator = coordinator
        self.profileMode = profileMode
        self.effectHandler = effectHandler
    }

    var isMonitoring: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    func start(promptForPermission: Bool = true) throws {
        try ensureHealthy(promptForPermission: promptForPermission)
    }

    func ensureHealthy(promptForPermission: Bool = false) throws {
        if promptForPermission, !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }

        switch HotkeyTapHealthPolicy.action(
            tapExists: eventTap != nil,
            tapEnabled: isMonitoring
        ) {
        case .keep:
            return
        case .create:
            try createTap()
        case .reenable:
            guard let eventTap else {
                try createTap()
                return
            }
            CGEvent.tapEnable(tap: eventTap, enable: true)
            let enabled = CGEvent.tapIsEnabled(tap: eventTap)
            if HotkeyTapHealthPolicy.action(
                tapExists: true,
                tapEnabled: false,
                reenableSucceeded: enabled
            ) == .rebuild {
                try rebuild(reason: "event tap remained disabled after re-enable")
            }
        case .rebuild:
            try rebuild(reason: "event tap health check requested rebuild")
        }
    }

    func rebuild(reason: String) throws {
        tapRebuildCount += 1
        lastTapDisableReason = reason
        reconcileConsumedDRelease(at: ProcessInfo.processInfo.systemUptime)
        destroyTap()
        try createTap()
    }

    func stop() {
        reconcileConsumedDRelease(at: ProcessInfo.processInfo.systemUptime)
        destroyTap()
        AppLogger.hotkey.info("Hyper+D event tap stopped")
    }

    private func createTap() throws {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            AppLogger.hotkey.error(
                "Unable to create event tap; Input Monitoring=\(CGPreflightListenEventAccess(), privacy: .public), Accessibility=\(AXIsProcessTrusted(), privacy: .public)"
            )
            throw GlobalKeyMonitorError.eventTapUnavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            destroyTap()
            throw GlobalKeyMonitorError.eventTapUnavailable
        }
        AppLogger.hotkey.info(
            "Hyper+D event tap started; Input Monitoring=\(CGPreflightListenEventAccess(), privacy: .public), Accessibility=\(AXIsProcessTrusted(), privacy: .public)"
        )
    }

    private func destroyTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        pendingKeyUps.removeAll()
        physicalDDown = false
        logicalDReleaseHandled = false
    }

    private nonisolated static let eventTapCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo, Thread.isMainThread else {
            return Unmanaged.passUnretained(event)
        }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
        return MainActor.assumeIsolated {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                manager.handleTapDisabled(type)
                return Unmanaged.passUnretained(event)
            }
            return manager.handle(type: type, event: event)
        }
    }

    private func handleTapDisabled(_ type: CGEventType) {
        tapDisableCount += 1
        let reason = type == .tapDisabledByTimeout ? "system timeout" : "user input"
        lastTapDisableReason = reason
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        guard !CGEvent.tapIsEnabled(tap: eventTap) else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.rebuild(reason: "tap disabled by \(reason) and re-enable failed")
            } catch {
                AppLogger.hotkey.error(
                    "Hyper+D event tap rebuild failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticPasteEventUserData {
            return Unmanaged.passUnretained(event)
        }

        let timestamp = ProcessInfo.processInfo.systemUptime
        expirePendingKeyUps(at: timestamp)
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isDKey = keyCode == UInt16(kVK_ANSI_D)
        let hyperD = isDKey && hasHyperModifiers(event.flags)
        var response = DictationEventResponse.passThrough

        if physicalDDown,
           !isDKey,
           !CGEventSource.keyState(
               .combinedSessionState,
               key: CGKeyCode(kVK_ANSI_D)
           ) {
            let recovery = releaseLogicalD(at: timestamp)
            dispatch(recovery.effects)
            physicalDDown = false
            logicalDReleaseHandled = false
        }

        switch type {
        case .flagsChanged:
            if physicalDDown,
               !logicalDReleaseHandled,
               !hasHyperModifiers(event.flags) {
                response = releaseLogicalD(at: timestamp)
                dispatch(response.effects)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown where hyperD:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat, physicalDDown {
                response = .consume
                break
            }
            if physicalDDown {
                let recovery = releaseLogicalD(at: timestamp)
                dispatch(recovery.effects)
                physicalDDown = false
                logicalDReleaseHandled = false
            }
            physicalDDown = true
            logicalDReleaseHandled = false
            response = coordinator.hotkeyDown(at: timestamp, profileMode: profileMode())

        case .keyUp where isDKey && physicalDDown:
            if !logicalDReleaseHandled {
                response = releaseLogicalD(at: timestamp)
            } else {
                response = .consume
            }
            physicalDDown = false
            logicalDReleaseHandled = false

        case .keyUp where pendingKeyUps.removeValue(forKey: keyCode) != nil:
            response = .consume

        case .keyDown where coordinator.phase.hasActiveSession:
            // A new down for the same key proves an older matching up was lost.
            pendingKeyUps.removeValue(forKey: keyCode)
            if keyCode == UInt16(kVK_Escape) {
                response = coordinator.escapePressed()
            } else if keyCode == UInt16(kVK_Return)
                        || keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                response = coordinator.enterPressed(
                    modifiers: enterModifiers(from: event.flags),
                    profileMode: profileMode()
                )
            } else {
                response = coordinator.nonModifierKeyTyped()
            }

        default:
            break
        }

        dispatch(response.effects)
        if type == .keyDown,
           response.consumeKeyEvent,
           (keyCode == UInt16(kVK_Return)
                || keyCode == UInt16(kVK_ANSI_KeypadEnter)
                || keyCode == UInt16(kVK_Escape)) {
            pendingKeyUps[keyCode] = PendingKeyUp(
                expiresAt: timestamp + Self.keyUpSuppressionLifetime
            )
        }
        return response.consumeKeyEvent ? nil : Unmanaged.passUnretained(event)
    }

    private func dispatch(_ effects: [DictationCoordinatorEffect]) {
        guard !effects.isEmpty else { return }
        effectHandler(effects)
    }

    private func releaseLogicalD(at timestamp: TimeInterval) -> DictationEventResponse {
        guard physicalDDown, !logicalDReleaseHandled else { return .consume }
        logicalDReleaseHandled = true
        return coordinator.hotkeyUp(at: timestamp, profileMode: profileMode())
    }

    private func reconcileConsumedDRelease(at timestamp: TimeInterval) {
        guard physicalDDown else { return }
        let response = releaseLogicalD(at: timestamp)
        dispatch(response.effects)
        physicalDDown = false
        logicalDReleaseHandled = false
    }

    private func expirePendingKeyUps(at timestamp: TimeInterval) {
        pendingKeyUps = pendingKeyUps.filter { $0.value.expiresAt > timestamp }
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

        // Caps Lock and numeric-pad are origin/state metadata, not unsupported
        // Return modifiers. Fail closed for other unclassified high bits.
        let classifiedFlags: CGEventFlags = [
            .maskAlternate,
            .maskShift,
            .maskCommand,
            .maskControl,
            .maskSecondaryFn,
            .maskNumericPad,
            .maskAlphaShift,
        ]
        let deviceIndependentFlags = flags.rawValue & ~UInt64(0xFFFF)
        if deviceIndependentFlags & ~classifiedFlags.rawValue != 0 {
            result.insert(.other)
        }
        return result
    }
}
