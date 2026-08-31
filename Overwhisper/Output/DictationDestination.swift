import AppKit

@MainActor
final class DictationDestination {
    struct CaptureCandidate {
        let processIdentifier: pid_t
        let bundleIdentifier: String
        let applicationName: String
        let role: String?
        let subrole: String?
        let focusedElementIsEditable: Bool
        let allowsFrontmostApplicationFallback: Bool
        let reactivateAndValidate: @MainActor () async -> Bool
        let remainsFocusedAndEditable: @MainActor () -> Bool

        init(
            processIdentifier: pid_t,
            bundleIdentifier: String,
            applicationName: String,
            role: String?,
            subrole: String?,
            focusedElementIsEditable: Bool,
            allowsFrontmostApplicationFallback: Bool = false,
            reactivateAndValidate: @escaping @MainActor () async -> Bool,
            remainsFocusedAndEditable: @escaping @MainActor () -> Bool
        ) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.applicationName = applicationName
            self.role = role
            self.subrole = subrole
            self.focusedElementIsEditable = focusedElementIsEditable
            self.allowsFrontmostApplicationFallback = allowsFrontmostApplicationFallback
            self.reactivateAndValidate = reactivateAndValidate
            self.remainsFocusedAndEditable = remainsFocusedAndEditable
        }
    }

    let processIdentifier: pid_t
    let bundleIdentifier: String
    let applicationName: String
    let role: String?
    let subrole: String?
    private let reactivateAndValidateHandler: @MainActor () async -> Bool
    private let remainsFocusedAndEditableHandler: @MainActor () -> Bool

    private init(candidate: CaptureCandidate) {
        processIdentifier = candidate.processIdentifier
        bundleIdentifier = candidate.bundleIdentifier
        applicationName = candidate.applicationName
        role = candidate.role
        subrole = candidate.subrole
        reactivateAndValidateHandler = candidate.reactivateAndValidate
        remainsFocusedAndEditableHandler = candidate.remainsFocusedAndEditable
    }

    static func captureFrontmost() -> DictationDestination? {
        captureFrontmost(candidateProvider: liveCaptureCandidate)
    }

    static func captureFrontmost(
        candidateProvider: () -> CaptureCandidate?
    ) -> DictationDestination? {
        guard let candidate = candidateProvider(),
              candidate.focusedElementIsEditable || candidate.allowsFrontmostApplicationFallback
        else {
            return nil
        }
        return DictationDestination(candidate: candidate)
    }

    func reactivateAndValidate() async -> Bool {
        await reactivateAndValidateHandler()
    }

    func remainsFocusedAndEditable() -> Bool {
        remainsFocusedAndEditableHandler()
    }

    private static func liveCaptureCandidate() -> CaptureCandidate? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }

        let processIdentifier = application.processIdentifier
        let focusedElement = focusedElement(for: processIdentifier)
        let focusedElementIsEditable = focusedElement.map(isEditable) ?? false
        return CaptureCandidate(
            processIdentifier: processIdentifier,
            bundleIdentifier: application.bundleIdentifier ?? "unknown",
            applicationName: application.localizedName ?? "Unknown application",
            role: focusedElement.flatMap { attribute(kAXRoleAttribute, from: $0) },
            subrole: focusedElement.flatMap { attribute(kAXSubroleAttribute, from: $0) },
            focusedElementIsEditable: focusedElementIsEditable,
            allowsFrontmostApplicationFallback: true,
            reactivateAndValidate: {
                if focusedElementIsEditable, let focusedElement {
                    return await reactivateAndValidate(
                        processIdentifier: processIdentifier,
                        focusedElement: focusedElement
                    )
                }
                return frontmostApplicationStillMatches(
                    processIdentifier: processIdentifier,
                    focusedElement: focusedElement
                )
            },
            remainsFocusedAndEditable: {
                if focusedElementIsEditable, let focusedElement {
                    return capturedElementRemainsFocusedAndEditable(
                        processIdentifier: processIdentifier,
                        focusedElement: focusedElement
                    )
                }
                return frontmostApplicationStillMatches(
                    processIdentifier: processIdentifier,
                    focusedElement: focusedElement
                )
            }
        )
    }

    /// Some web and Electron editors accept Command+V while declining to expose
    /// a settable AXSelectedTextRange. For those destinations, paste only while
    /// the same application—and the same AX focus token when one exists—remains
    /// frontmost. This is intentionally weaker than direct Accessibility
    /// validation but still prevents a delayed paste from following an app or
    /// field switch during transcription cleanup.
    private static func frontmostApplicationStillMatches(
        processIdentifier: pid_t,
        focusedElement: AXUIElement?
    ) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated,
              application.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
        else { return false }

        guard let focusedElement else { return true }
        guard let currentElement = Self.focusedElement(for: processIdentifier) else { return false }
        return CFEqual(currentElement, focusedElement)
    }

    private static func reactivateAndValidate(
        processIdentifier: pid_t,
        focusedElement: AXUIElement
    ) async -> Bool {
        guard !Task.isCancelled,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated
        else { return false }

        if !application.isActive {
            _ = application.activate()
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return false
            }
        }

        return capturedElementRemainsFocusedAndEditable(
            processIdentifier: processIdentifier,
            focusedElement: focusedElement
        )
    }

    private static func capturedElementRemainsFocusedAndEditable(
        processIdentifier: pid_t,
        focusedElement: AXUIElement
    ) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated,
              application.isActive,
              let currentElement = Self.focusedElement(for: processIdentifier),
              isEditable(currentElement)
        else { return false }

        return CFEqual(currentElement, focusedElement)
    }

    private static func focusedElement(for processIdentifier: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }

        return (value as! AXUIElement)
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
}
