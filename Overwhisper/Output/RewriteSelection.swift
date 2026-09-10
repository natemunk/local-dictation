import AppKit
import os

/// Immutable AX references cross to a single serial queue; all messaging is bounded.
struct RewriteSelection: @unchecked Sendable {
    let pid: pid_t
    let bundleID: String
    let element: AXUIElement
    let text: String
    let range: CFRange
    let editable: Bool
    let terminal: Bool
    let role: String

    var supportsReplacement: Bool {
        editable && !terminal && role == kAXTextAreaRole && range.location >= 0 && range.length > 0 && RewriteEditorCompatibility.replacement.contains(bundleID.lowercased())
    }
    var supportsInsertAfter: Bool {
        supportsReplacement && RewriteEditorCompatibility.insertAfter.contains(bundleID.lowercased())
    }
}

/// Only profiles with recorded live acceptance belong here. Copy works independently.
enum RewriteEditorCompatibility {
    static let replacement: Set<String> = ["com.apple.textedit"]
    static let insertAfter: Set<String> = ["com.apple.textedit"]
}

enum RewriteSelectionResult: @unchecked Sendable {
    case selected(RewriteSelection)
    case empty
    case unavailable
    case excludedOwnProcess
    case protected
    var isProtected: Bool { if case .protected = self { return true }; return false }
}

/// One AX operation at a time. A UI timeout abandons its result, not its thread.
/// This avoids blocking the main actor and prevents accumulating AX work.
final class RewriteSelectionAccess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local-dictation.rewrite-accessibility", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private let operationLimit: TimeInterval
    init(operationLimit: TimeInterval = 0.25) { self.operationLimit = operationLimit }
    private static let logger = Logger(subsystem: AppLogger.subsystem, category: "rewrite_selection")

    @MainActor
    func captureFrontmost() async -> RewriteSelectionResult {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unavailable }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return .excludedOwnProcess }
        guard AXIsProcessTrusted() else { return .unavailable }
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier ?? ""
        let result = await perform(fallback: RewriteSelectionResult.unavailable) { deadline in
            Self.capture(pid: pid, bundle: bundle, deadline: deadline)
        }
        let code: String
        switch result {
        case .selected: code = "selected"
        case .empty: code = "empty"
        case .excludedOwnProcess: code = "own_process_excluded"
        case .unavailable: code = "unavailable"
        case .protected: code = "protected"
        }
        Self.logger.info("Selection capture outcome=\(code, privacy: .public)")
        return result
    }

    @MainActor
    func validate(_ selection: RewriteSelection, collapsed: Bool = false) async -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == selection.pid else { return false }
        return await perform(fallback: false) { deadline in
            Self.matches(selection, collapsed: collapsed, deadline: deadline)
        }
    }

    @MainActor
    func collapseAfter(_ selection: RewriteSelection) async -> Bool {
        guard selection.supportsInsertAfter, NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.pid else { return false }
        return await perform(fallback: false) { deadline in
            guard Self.matches(selection, deadline: deadline) else { return false }
            var range = CFRange(location: selection.range.location + selection.range.length, length: 0)
            guard let value = AXValueCreate(.cfRange, &range), Self.withTime(selection.element, deadline: deadline),
                  AXUIElementSetAttributeValue(selection.element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
            return Self.matches(selection, collapsed: true, deadline: deadline)
        }
    }

    private func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }
    private func release() { lock.lock(); busy = false; lock.unlock() }

    func perform<T: Sendable>(fallback: T, work: @escaping @Sendable (ContinuousClock.Instant) -> T) async -> T {
        guard !Task.isCancelled, reserve() else { return fallback }
        let deadline = ContinuousClock.now.advanced(by: .seconds(operationLimit))
        let start = ContinuousClock.now
        return await withCheckedContinuation { continuation in
            let reply = AXReply(continuation)
            queue.async { [self] in
                let result = work(deadline)
                release()
                reply.finish(ContinuousClock.now <= deadline ? result : fallback)
                let elapsed = start.duration(to: .now).components
                let ms = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
                Self.logger.info("Selection operation drained milliseconds=\(ms)")
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + operationLimit) { reply.finish(fallback) }
        }
    }

    private static func capture(pid: pid_t, bundle: String, deadline: ContinuousClock.Instant) -> RewriteSelectionResult {
        let app = AXUIElementCreateApplication(pid)
        guard let element = elementAttribute(kAXFocusedUIElementAttribute, from: app, deadline: deadline) else { return .unavailable }
        // Require known role/subrole; uncertain protection is not permission to read.
        guard let role = stringAttribute(kAXRoleAttribute, from: element, deadline: deadline) else { return .unavailable }
        let subrole = stringAttribute(kAXSubroleAttribute, from: element, deadline: deadline) ?? ""
        if role.lowercased().contains("secure") || subrole.lowercased().contains("secure") || subrole.lowercased().contains("password") { return .protected }
        if (attribute("AXProtectedContent", from: element, deadline: deadline) as? Bool) == true { return .protected }
        let content = Self.classifyContent(range: selectedRange(element, deadline: deadline)) {
            stringAttribute(kAXSelectedTextAttribute, from: element, deadline: deadline)
        }
        let text: String, range: CFRange
        switch content {
        case .empty: return .empty
        case .unavailable: return .unavailable
        case .selected(let value, let selectionRange): text = value; range = selectionRange
        }
        guard withTime(element, deadline: deadline) else { return .unavailable }
        var editable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &editable)
        let terminal = ["com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp", "dev.warp.warp-stable"].contains(bundle.lowercased())
            || role.lowercased().contains("terminal") || subrole.lowercased().contains("terminal")
        return .selected(RewriteSelection(pid: pid, bundleID: bundle, element: element, text: text, range: range,
                                          editable: editable.boolValue, terminal: terminal, role: role))
    }

    enum Content {
        case empty, unavailable
        case selected(String, CFRange)
    }

    /// Missing/unsupported attributes are unknown, not evidence of an empty selection.
    /// Laziness also avoids reading selected text for a collapsed or invalid range.
    static func classifyContent(range: CFRange?, readText: () -> String?) -> Content {
        if let range {
            guard range.location >= 0, range.length >= 0,
                  range.location <= Int.max - range.length, range.length <= 12_000 else { return .unavailable }
            if range.length == 0 { return .empty }
        }
        guard let text = readText(), !text.isEmpty, text.utf8.count <= 12_000 else { return .unavailable }
        let verified = range.flatMap { $0.length == text.utf16.count ? $0 : nil } ?? CFRange(location: -1, length: 0)
        return .selected(text, verified)
    }

    private static func matches(_ selection: RewriteSelection, collapsed: Bool = false, deadline: ContinuousClock.Instant) -> Bool {
        let app = AXUIElementCreateApplication(selection.pid)
        guard let focus = elementAttribute(kAXFocusedUIElementAttribute, from: app, deadline: deadline),
              CFEqual(focus, selection.element),
              let range = selectedRange(focus, deadline: deadline) else { return false }
        let subrole = stringAttribute(kAXSubroleAttribute, from: focus, deadline: deadline) ?? ""
        guard !subrole.lowercased().contains("secure"), !subrole.lowercased().contains("password"),
              (attribute("AXProtectedContent", from: focus, deadline: deadline) as? Bool) != true else { return false }
        guard let role = stringAttribute(kAXRoleAttribute, from: focus, deadline: deadline), role == selection.role,
              withTime(focus, deadline: deadline) else { return false }
        var editable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(focus, kAXSelectedTextAttribute as CFString, &editable) == .success,
              editable.boolValue else { return false }
        if collapsed {
            return range.location == selection.range.location + selection.range.length && range.length == 0
        }
        guard range.location == selection.range.location, range.length == selection.range.length else { return false }
        return stringAttribute(kAXSelectedTextAttribute, from: focus, deadline: deadline) == selection.text
    }

    private static func withTime(_ element: AXUIElement, deadline: ContinuousClock.Instant) -> Bool {
        let left = ContinuousClock.now.duration(to: deadline)
        guard left > .zero else { return false }
        let c = left.components
        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        AXUIElementSetMessagingTimeout(element, Float(min(0.2, seconds)))
        return true
    }
    private static func attribute(_ name: String, from element: AXUIElement, deadline: ContinuousClock.Instant) -> CFTypeRef? {
        guard withTime(element, deadline: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func stringAttribute(_ name: String, from element: AXUIElement, deadline: ContinuousClock.Instant) -> String? {
        attribute(name, from: element, deadline: deadline) as? String
    }
    private static func elementAttribute(_ name: String, from element: AXUIElement, deadline: ContinuousClock.Instant) -> AXUIElement? {
        guard let value = attribute(name, from: element, deadline: deadline), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func selectedRange(_ element: AXUIElement, deadline: ContinuousClock.Instant) -> CFRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, from: element, deadline: deadline), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range) else { return nil }
        return range
    }
}

private final class AXReply<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    func finish(_ result: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}
