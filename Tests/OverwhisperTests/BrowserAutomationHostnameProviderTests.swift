import Foundation
import Testing
@testable import LocalDictation

@Suite("Browser automation hostname provider")
struct BrowserAutomationHostnameProviderTests {
    @Test("active URL path, query, and fragment are discarded")
    @MainActor
    func urlRedaction() async throws {
        let runner = StubBrowserAutomationScriptRunner(
            results: [
                .activeURL(
                    "https://docs.example.com/private/account/42?token=secret#confidential"
                )
            ]
        )
        let provider = BrowserAutomationHostnameProvider(
            scriptRunner: runner,
            outcomeStore: InMemoryBrowserAutomationOutcomeStore()
        )

        let hostname = try await provider.hostname(
            for: BrowserHostnameRequest(
                browserBundleIdentifier: "com.apple.Safari",
                approvedDomains: ["example.com"]
            )
        )

        #expect(hostname?.value == "docs.example.com")
        #expect(hostname?.value.contains("/") == false)
        #expect(hostname?.value.contains("?") == false)
        #expect(hostname?.value.contains("#") == false)
    }

    @Test("allowlist accepts exact hosts and subdomains but rejects lookalikes")
    @MainActor
    func domainAllowlist() async throws {
        let cases: [(String, String?)] = [
            ("https://example.com/private", "example.com"),
            ("https://deep.docs.example.com/private", "deep.docs.example.com"),
            ("https://example.com.attacker.test/private", nil),
            ("https://notexample.com/private", nil),
        ]

        for (activeURL, expectedHostname) in cases {
            let runner = StubBrowserAutomationScriptRunner(results: [.activeURL(activeURL)])
            let provider = BrowserAutomationHostnameProvider(
                scriptRunner: runner,
                outcomeStore: InMemoryBrowserAutomationOutcomeStore()
            )

            let hostname = try await provider.hostname(
                for: BrowserHostnameRequest(
                    browserBundleIdentifier: "org.chromium.Chromium",
                    approvedDomains: ["example.com"]
                )
            )

            #expect(hostname?.value == expectedHostname)
        }
    }

    @Test("unsupported browsers are skipped without invoking AppleScript")
    @MainActor
    func unsupportedBrowser() async throws {
        let runner = StubBrowserAutomationScriptRunner(
            results: [.activeURL("https://example.com/private")]
        )
        let store = InMemoryBrowserAutomationOutcomeStore()
        let provider = BrowserAutomationHostnameProvider(
            scriptRunner: runner,
            outcomeStore: store
        )
        let request = BrowserHostnameRequest(
            browserBundleIdentifier: "org.mozilla.firefox",
            approvedDomains: ["example.com"]
        )

        #expect(try await provider.hostname(for: request) == nil)
        #expect(try await provider.hostname(for: request) == nil)
        #expect(runner.invocationCount == 0)
        #expect(await store.outcome(for: "org.mozilla.firefox") == .unsupported)
    }

    @Test("denial is persisted per browser and suppresses later attempts")
    @MainActor
    func denialMemoization() async throws {
        let suiteName = "BrowserAutomationHostnameProviderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let deniedRunner = StubBrowserAutomationScriptRunner(results: [.denied])
        let firstProvider = BrowserAutomationHostnameProvider(
            scriptRunner: deniedRunner,
            outcomeStore: UserDefaultsBrowserAutomationOutcomeStore(defaults: defaults)
        )
        let request = BrowserHostnameRequest(
            browserBundleIdentifier: "com.google.Chrome",
            approvedDomains: ["example.com"]
        )

        #expect(try await firstProvider.hostname(for: request) == nil)
        #expect(deniedRunner.invocationCount == 1)

        let laterRunner = StubBrowserAutomationScriptRunner(
            results: [.activeURL("https://example.com/private")]
        )
        let laterProvider = BrowserAutomationHostnameProvider(
            scriptRunner: laterRunner,
            outcomeStore: UserDefaultsBrowserAutomationOutcomeStore(defaults: defaults)
        )

        #expect(try await laterProvider.hostname(for: request) == nil)
        #expect(laterRunner.invocationCount == 0)
    }
}

@MainActor
private final class StubBrowserAutomationScriptRunner: BrowserAutomationScriptRunning {
    private var results: [BrowserAutomationScriptResult]
    private(set) var invocationCount = 0

    init(results: [BrowserAutomationScriptResult]) {
        self.results = results
    }

    func execute(source: String) -> BrowserAutomationScriptResult {
        invocationCount += 1
        guard !results.isEmpty else { return .unavailable }
        return results.removeFirst()
    }
}

private actor InMemoryBrowserAutomationOutcomeStore: BrowserAutomationOutcomePersisting {
    private var outcomes: [String: BrowserAutomationTerminalOutcome] = [:]

    func outcome(for browserBundleIdentifier: String) -> BrowserAutomationTerminalOutcome? {
        outcomes[browserBundleIdentifier.lowercased()]
    }

    func persist(
        _ outcome: BrowserAutomationTerminalOutcome,
        for browserBundleIdentifier: String
    ) {
        outcomes[browserBundleIdentifier.lowercased()] = outcome
    }
}
