import AppKit

enum DestinationInsertionTier: String, Equatable, Sendable {
    case exactEditableElement
    case allowlistedFocusToken
}

@MainActor
final class DictationDestination {
    struct CaptureCandidate {
        let processIdentifier: pid_t
        let bundleIdentifier: String
        let applicationName: String
        let role: String?
        let subrole: String?
        let focusTokenAvailable: Bool
        let focusedElementIsEditable: Bool
        let focusedElementIsSecure: Bool
        let focusedElementIsTerminal: Bool
        let allowsFocusTokenFallback: Bool
        let validateForInsertion: @MainActor (_ reactivateIfNeeded: Bool) async -> Bool
        let remainsValidForInsertion: @MainActor () -> Bool

        init(
            processIdentifier: pid_t,
            bundleIdentifier: String,
            applicationName: String,
            role: String?,
            subrole: String?,
            focusTokenAvailable: Bool,
            focusedElementIsEditable: Bool,
            focusedElementIsSecure: Bool = false,
            focusedElementIsTerminal: Bool = false,
            allowsFocusTokenFallback: Bool = false,
            validateForInsertion: @escaping @MainActor (_ reactivateIfNeeded: Bool) async -> Bool,
            remainsValidForInsertion: @escaping @MainActor () -> Bool
        ) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.applicationName = applicationName
            self.role = role
            self.subrole = subrole
            self.focusTokenAvailable = focusTokenAvailable
            self.focusedElementIsEditable = focusedElementIsEditable
            self.focusedElementIsSecure = focusedElementIsSecure
            self.focusedElementIsTerminal = focusedElementIsTerminal
            self.allowsFocusTokenFallback = allowsFocusTokenFallback
            self.validateForInsertion = validateForInsertion
            self.remainsValidForInsertion = remainsValidForInsertion
        }
    }

    private static let axMessagingTimeout: Float = 0.20
    private static let focusObservationDeadline = Duration.milliseconds(250)
    private static let focusObservationInterval = Duration.milliseconds(10)

    /// Tier two is deliberately a closed product allowlist. A focused AX token
    /// is still mandatory; these bundle IDs never receive a PID-only paste.
    private static let focusTokenFallbackBundleIdentifiers: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.linear",
        "com.apple.safari",
        "com.google.chrome",
        "com.google.chrome.canary",
        "org.chromium.chromium",
        "notion.id",
        "com.notion.id",
    ]

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp",
        "dev.warp.warp-stable",
    ]

    private static let visualStudioCodeBundleIdentifiers: Set<String> = [
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.vscodium",
        "com.visualstudio.code.oss",
    ]

    let processIdentifier: pid_t
    let bundleIdentifier: String
    let applicationName: String
    let role: String?
    let subrole: String?
    let insertionTier: DestinationInsertionTier?
    let isSecureField: Bool
    let isTerminal: Bool
    private let validateForInsertionHandler: @MainActor (Bool) async -> Bool
    private let remainsValidForInsertionHandler: @MainActor () -> Bool

    private init(candidate: CaptureCandidate, insertionTier: DestinationInsertionTier?) {
        processIdentifier = candidate.processIdentifier
        bundleIdentifier = candidate.bundleIdentifier
        applicationName = candidate.applicationName
        role = candidate.role
        subrole = candidate.subrole
        self.insertionTier = insertionTier
        isSecureField = candidate.focusedElementIsSecure
        isTerminal = candidate.focusedElementIsTerminal
        validateForInsertionHandler = candidate.validateForInsertion
        remainsValidForInsertionHandler = candidate.remainsValidForInsertion
    }

    static func captureFrontmost() -> DictationDestination? {
        captureFrontmost(candidateProvider: liveCaptureCandidate)
    }

    static func captureFrontmost(
        candidateProvider: () -> CaptureCandidate?
    ) -> DictationDestination? {
        guard let candidate = candidateProvider() else { return nil }

        let insertionTier: DestinationInsertionTier?
        if candidate.focusTokenAvailable && candidate.focusedElementIsEditable {
            insertionTier = .exactEditableElement
        } else if candidate.focusTokenAvailable && candidate.allowsFocusTokenFallback {
            insertionTier = .allowlistedFocusToken
        } else {
            insertionTier = nil
        }

        // Secure fields must remain representable so finalization can discard
        // audio before batch ASR. Every nonsecure destination needs a concrete
        // AX focus token and one of the two explicit insertion tiers.
        guard candidate.focusedElementIsSecure || insertionTier != nil else {
            return nil
        }
        return DictationDestination(candidate: candidate, insertionTier: insertionTier)
    }

    func validateForInsertion(reactivateIfNeeded: Bool) async -> Bool {
        guard !isSecureField, insertionTier != nil else { return false }
        return await validateForInsertionHandler(reactivateIfNeeded)
    }

    func remainsValidForInsertion() -> Bool {
        guard !isSecureField, insertionTier != nil else { return false }
        return remainsValidForInsertionHandler()
    }

    static func isApprovedFocusTokenFallback(bundleIdentifier: String) -> Bool {
        focusTokenFallbackBundleIdentifiers.contains(bundleIdentifier.lowercased())
    }

    static func classifiesSecureField(
        role: String?,
        subrole: String?,
        protectedContent: Bool
    ) -> Bool {
        if protectedContent { return true }
        return [role, subrole]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("secure") || $0.contains("password") }
    }

    static func classifiesTerminal(
        bundleIdentifier: String,
        role: String?,
        subrole: String?,
        identifier: String?,
        description: String?
    ) -> Bool {
        let bundle = bundleIdentifier.lowercased()
        if terminalBundleIdentifiers.contains(bundle) { return true }
        guard visualStudioCodeBundleIdentifiers.contains(bundle) else { return false }

        // VS Code editors and terminals share a bundle ID. Require focused AX
        // metadata to identify the integrated terminal; the strings themselves
        // are immediately discarded and never stored or logged.
        return [role, subrole, identifier, description]
            .compactMap { $0?.lowercased() }
            .contains { value in
                value == "axterminal" || value.contains("terminal")
            }
    }

    private static func liveCaptureCandidate() -> CaptureCandidate? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }

        let processIdentifier = application.processIdentifier
        let bundleIdentifier = application.bundleIdentifier ?? "unknown"
        let focusedElement = focusedElement(for: processIdentifier)
        let role = focusedElement.flatMap { attribute(kAXRoleAttribute, from: $0) }
        let subrole = focusedElement.flatMap { attribute(kAXSubroleAttribute, from: $0) }
        let protectedContent = focusedElement.map {
            boolAttribute("AXProtectedContent", from: $0)
        } ?? false
        let isSecure = classifiesSecureField(
            role: role,
            subrole: subrole,
            protectedContent: protectedContent
        )
        let isEditable = focusedElement.map(isEditable) ?? false
        let identifier = focusedElement.flatMap { attribute("AXIdentifier", from: $0) }
        let description = focusedElement.flatMap { attribute(kAXDescriptionAttribute, from: $0) }
        let isTerminal = classifiesTerminal(
            bundleIdentifier: bundleIdentifier,
            role: role,
            subrole: subrole,
            identifier: identifier,
            description: description
        )
        let allowsFallback = focusedElement != nil
            && isApprovedFocusTokenFallback(bundleIdentifier: bundleIdentifier)

        return CaptureCandidate(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            applicationName: application.localizedName ?? "Unknown application",
            role: role,
            subrole: subrole,
            focusTokenAvailable: focusedElement != nil,
            focusedElementIsEditable: isEditable,
            focusedElementIsSecure: isSecure,
            focusedElementIsTerminal: isTerminal,
            allowsFocusTokenFallback: allowsFallback,
            validateForInsertion: { reactivateIfNeeded in
                guard let focusedElement else { return false }
                return await reactivateAndValidate(
                    processIdentifier: processIdentifier,
                    focusedElement: focusedElement,
                    requiresEditableElement: isEditable,
                    reactivateIfNeeded: reactivateIfNeeded
                )
            },
            remainsValidForInsertion: {
                guard let focusedElement else { return false }
                return capturedElementRemainsValid(
                    processIdentifier: processIdentifier,
                    focusedElement: focusedElement,
                    requiresEditableElement: isEditable
                )
            }
        )
    }

    private static func reactivateAndValidate(
        processIdentifier: pid_t,
        focusedElement: AXUIElement,
        requiresEditableElement: Bool,
        reactivateIfNeeded: Bool
    ) async -> Bool {
        guard !Task.isCancelled,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated
        else { return false }

        if !application.isActive {
            guard reactivateIfNeeded else { return false }
            _ = application.activate()
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: focusObservationDeadline)
        repeat {
            if capturedElementRemainsValid(
                processIdentifier: processIdentifier,
                focusedElement: focusedElement,
                requiresEditableElement: requiresEditableElement
            ) {
                return true
            }
            guard reactivateIfNeeded, clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: focusObservationInterval)
            } catch {
                return false
            }
        } while !Task.isCancelled

        return false
    }

    private static func capturedElementRemainsValid(
        processIdentifier: pid_t,
        focusedElement: AXUIElement,
        requiresEditableElement: Bool
    ) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated,
              application.isActive,
              let currentElement = Self.focusedElement(for: processIdentifier),
              CFEqual(currentElement, focusedElement)
        else { return false }

        return !requiresEditableElement || isEditable(currentElement)
    }

    private static func focusedElement(for processIdentifier: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }

        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        return element
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &isSettable
        ) == .success
        else { return false }

        return isSettable.boolValue
    }

    private static func attribute(_ name: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(_ name: String, from element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }
}
