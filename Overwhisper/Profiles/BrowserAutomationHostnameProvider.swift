import Foundation

/// A terminal browser-automation outcome that should survive adapter instances.
/// Neither case carries browser content or an AppleScript error description.
enum BrowserAutomationTerminalOutcome: String, Equatable, Sendable {
    case denied
    case unsupported
}

protocol BrowserAutomationOutcomePersisting: Sendable {
    func outcome(for browserBundleIdentifier: String) async -> BrowserAutomationTerminalOutcome?
    func persist(
        _ outcome: BrowserAutomationTerminalOutcome,
        for browserBundleIdentifier: String
    ) async
}

/// Persists only a per-browser terminal outcome. URLs and hostnames are never
/// accepted by this store and therefore cannot enter UserDefaults through it.
actor UserDefaultsBrowserAutomationOutcomeStore: BrowserAutomationOutcomePersisting {
    private static let keyPrefix = "browser-automation.terminal-outcome."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func outcome(for browserBundleIdentifier: String) -> BrowserAutomationTerminalOutcome? {
        guard let rawValue = defaults.string(forKey: key(for: browserBundleIdentifier)) else {
            return nil
        }
        return BrowserAutomationTerminalOutcome(rawValue: rawValue)
    }

    func persist(
        _ outcome: BrowserAutomationTerminalOutcome,
        for browserBundleIdentifier: String
    ) {
        defaults.set(outcome.rawValue, forKey: key(for: browserBundleIdentifier))
    }

    private func key(for browserBundleIdentifier: String) -> String {
        Self.keyPrefix + browserBundleIdentifier.lowercased()
    }
}

/// The raw URL exists only in this adapter boundary and is consumed immediately
/// by `BrowserAutomationHostnameProvider`. It is never used as an error value.
enum BrowserAutomationScriptResult: Equatable, Sendable {
    case activeURL(String)
    case unavailable
    case denied
    case unsupported
}

protocol BrowserAutomationScriptRunning: Sendable {
    /// NSAppleScript is main-thread-only. Injecting this boundary lets tests
    /// return deterministic results without sending Apple Events.
    @MainActor
    func execute(source: String) -> BrowserAutomationScriptResult
}

struct NSAppleScriptBrowserAutomationRunner: BrowserAutomationScriptRunning {
    @MainActor
    func execute(source: String) -> BrowserAutomationScriptResult {
        guard let script = NSAppleScript(source: source) else {
            return .unsupported
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if let errorNumber = (errorInfo?[NSAppleScript.errorNumber] as? NSNumber)?.intValue {
            switch errorNumber {
            case -1743, -10004:
                // Apple Events access denied / privilege error.
                return .denied
            case -1708:
                // The target application does not handle the requested event.
                return .unsupported
            default:
                // Treat all other script/application failures as transient and
                // omit their descriptions because they may contain page data.
                return .unavailable
            }
        }

        guard let activeURL = descriptor.stringValue, !activeURL.isEmpty else {
            return .unavailable
        }
        return .activeURL(activeURL)
    }
}

/// Reads the active tab only when explicitly invoked by profile resolution,
/// immediately reduces the result to a hostname, and returns it only when it is
/// covered by the caller's exact-or-subdomain allowlist.
actor BrowserAutomationHostnameProvider: BrowserHostnameProviding {
    private let scriptRunner: any BrowserAutomationScriptRunning
    private let outcomeStore: any BrowserAutomationOutcomePersisting
    private var inFlightBrowsers: Set<String> = []

    init(
        scriptRunner: any BrowserAutomationScriptRunning = NSAppleScriptBrowserAutomationRunner(),
        outcomeStore: any BrowserAutomationOutcomePersisting = UserDefaultsBrowserAutomationOutcomeStore()
    ) {
        self.scriptRunner = scriptRunner
        self.outcomeStore = outcomeStore
    }

    func hostname(for request: BrowserHostnameRequest) async throws -> BrowserHostname? {
        let approvedDomains = Set(
            request.approvedDomains.compactMap(BrowserHostname.approvedDomain(from:))
        )
        guard !approvedDomains.isEmpty else { return nil }

        let requestedIdentifier = request.browserBundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedIdentifier.isEmpty else { return nil }

        let persistenceIdentifier = requestedIdentifier.lowercased()
        guard !inFlightBrowsers.contains(persistenceIdentifier) else { return nil }
        inFlightBrowsers.insert(persistenceIdentifier)
        defer { inFlightBrowsers.remove(persistenceIdentifier) }

        guard await outcomeStore.outcome(for: persistenceIdentifier) == nil else {
            return nil
        }

        guard let target = BrowserAutomationTarget.resolve(requestedIdentifier) else {
            await outcomeStore.persist(.unsupported, for: persistenceIdentifier)
            return nil
        }

        let result = await scriptRunner.execute(source: target.scriptSource)
        switch result {
        case .activeURL(let activeURL):
            // This is the only point at which the full URL exists above the
            // script runner. Reduce it immediately and never retain or expose it.
            guard let hostname = BrowserHostname(activeURL),
                  approvedDomains.contains(where: { approvedDomain in
                      hostname.value == approvedDomain
                          || hostname.value.hasSuffix(".\(approvedDomain)")
                  })
            else {
                return nil
            }
            return hostname

        case .denied:
            await outcomeStore.persist(.denied, for: persistenceIdentifier)
            return nil

        case .unsupported:
            await outcomeStore.persist(.unsupported, for: persistenceIdentifier)
            return nil

        case .unavailable:
            return nil
        }
    }
}

private struct BrowserAutomationTarget: Sendable {
    enum Dialect: Sendable {
        case safari
        case chromium
    }

    let bundleIdentifier: String
    let dialect: Dialect

    var scriptSource: String {
        let activeTabReference: String
        switch dialect {
        case .safari:
            activeTabReference = "current tab"
        case .chromium:
            activeTabReference = "active tab"
        }

        // bundleIdentifier comes exclusively from the fixed map below; request
        // values are never interpolated into AppleScript source.
        return """
        tell application id "\(bundleIdentifier)"
            if (count of windows) is 0 then return ""
            set activeURL to URL of \(activeTabReference) of front window
            if activeURL is missing value then return ""
            return activeURL as text
        end tell
        """
    }

    static func resolve(_ bundleIdentifier: String) -> BrowserAutomationTarget? {
        targets[bundleIdentifier.lowercased()]
    }

    private static let targets: [String: BrowserAutomationTarget] = {
        var targets: [String: BrowserAutomationTarget] = [:]

        func add(_ bundleIdentifier: String, dialect: Dialect) {
            targets[bundleIdentifier.lowercased()] = BrowserAutomationTarget(
                bundleIdentifier: bundleIdentifier,
                dialect: dialect
            )
        }

        add("com.apple.Safari", dialect: .safari)
        add("com.apple.SafariTechnologyPreview", dialect: .safari)

        add("com.google.Chrome", dialect: .chromium)
        add("com.google.Chrome.beta", dialect: .chromium)
        add("com.google.Chrome.dev", dialect: .chromium)
        add("com.google.Chrome.canary", dialect: .chromium)
        add("org.chromium.Chromium", dialect: .chromium)
        add("com.brave.Browser", dialect: .chromium)
        add("com.brave.Browser.beta", dialect: .chromium)
        add("com.brave.Browser.nightly", dialect: .chromium)
        add("com.microsoft.edgemac", dialect: .chromium)
        add("com.microsoft.edgemac.Beta", dialect: .chromium)
        add("com.microsoft.edgemac.Dev", dialect: .chromium)
        add("com.microsoft.edgemac.Canary", dialect: .chromium)
        add("com.vivaldi.Vivaldi", dialect: .chromium)
        add("com.operasoftware.Opera", dialect: .chromium)
        add("company.thebrowser.Browser", dialect: .chromium)

        return targets
    }()
}
