import Testing
@testable import LocalDictation

@Suite("Profile resolution")
struct ProfileResolverTests {
    @Test("native app defaults resolve by bundle identifier")
    func nativeAppDefaults() {
        let resolver = ProfileResolver(catalog: .nativeDefaults)
        let cases = [
            ("com.mitchellh.ghostty", "ghostty"),
            ("com.tinyspeck.slackmacgap", "slack"),
            ("com.linear", "linear"),
            ("com.apple.Notes", "notes"),
            ("notion.id", "notion"),
            ("com.apple.Safari", "browser"),
            ("com.unknown.App", "default"),
        ]

        for (bundleIdentifier, expectedProfileID) in cases {
            let result = resolver.resolve(
                ProfileResolutionContext(bundleIdentifier: bundleIdentifier)
            )
            #expect(result.profile.id == expectedProfileID)
        }
    }

    @Test("bundle identity wins globally and AX role then subrole refine within the app")
    func profilePrecedence() {
        var catalog = ProfileCatalog.nativeDefaults
        catalog.profiles["any-text-area"] = DictationProfile(
            id: "any-text-area",
            mode: .clean,
            formattingStyle: .plain,
            cleanupEnabled: false,
            priority: 9_000,
            match: ProfileMatch(accessibilityRoles: ["AXTextArea"])
        )
        catalog.profiles["slack-compose"] = DictationProfile(
            id: "slack-compose",
            mode: .clean,
            formattingStyle: .chat,
            cleanupEnabled: true,
            match: ProfileMatch(
                bundleIdentifiers: ["com.tinyspeck.slackmacgap"],
                accessibilityRoles: ["AXTextArea"],
                accessibilitySubroles: ["AXComposeArea"]
            )
        )

        let resolver = ProfileResolver(catalog: catalog)
        let refined = resolver.resolve(
            ProfileResolutionContext(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                accessibilityRole: "AXTextArea",
                accessibilitySubrole: "AXComposeArea"
            )
        )
        #expect(refined.profile.id == "slack-compose")
        #expect(refined.source == .bundleIdentifier)

        let baseApp = resolver.resolve(
            ProfileResolutionContext(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                accessibilityRole: "AXTextArea",
                accessibilitySubrole: "AXOther"
            )
        )
        #expect(baseApp.profile.id == "slack")

        let accessibilityFallback = resolver.resolve(
            ProfileResolutionContext(
                bundleIdentifier: "com.example.Editor",
                accessibilityRole: "AXTextArea"
            )
        )
        #expect(accessibilityFallback.profile.id == "any-text-area")
        #expect(accessibilityFallback.source == .accessibility)
    }

    @Test("terminal safety cannot be weakened by a configuration override")
    func terminalSafetyOverride() {
        let configured = DictationProfile(
            id: "terminal",
            mode: .clean,
            formattingStyle: .structured,
            cleanupEnabled: true,
            vocabularyPackIDs: ["personal"]
        )

        let safe = TerminalProfilePolicy.enforcingSafety(on: configured)

        #expect(safe.mode == .literal)
        #expect(safe.formattingStyle == .terminal)
        #expect(!safe.cleanupEnabled)
        #expect(safe.vocabularyPackIDs == ["personal"])
    }

    @Test("approved hostname can refine a browser without retaining its path")
    func hostnameFallback() throws {
        let resolver = ProfileResolver(
            catalog: .nativeDefaults,
            browserProfilesEnabled: true
        )
        let hostname = try #require(
            BrowserHostname("https://linear.app/acme/issue/MYE-2076?view=full")
        )
        #expect(hostname.value == "linear.app")
        #expect(!hostname.value.contains("/"))

        let linear = resolver.resolve(
            ProfileResolutionContext(
                bundleIdentifier: "com.google.Chrome",
                browserHostname: hostname
            )
        )
        #expect(linear.profile.id == "linear")
        #expect(linear.source == .hostname)

        let unknown = resolver.resolve(
            ProfileResolutionContext(
                bundleIdentifier: "com.google.Chrome",
                browserHostname: BrowserHostname("https://example.com/private/path")
            )
        )
        #expect(unknown.profile.id == "browser")
        #expect(unknown.source == .genericBrowser)

        let nativeAppWins = resolver.resolve(
            ProfileResolutionContext(
                bundleIdentifier: "com.mitchellh.ghostty",
                browserHostname: hostname
            )
        )
        #expect(nativeAppWins.profile.id == "ghostty")

        let disabled = ProfileResolver(catalog: .nativeDefaults).resolve(
            ProfileResolutionContext(
                bundleIdentifier: "com.google.Chrome",
                browserHostname: hostname
            )
        )
        #expect(disabled.profile.id == "browser")
    }

    @Test("hostname acquisition remains behind a pure protocol")
    func hostnameProviderBoundary() async throws {
        let resolver = ProfileResolver(
            catalog: .nativeDefaults,
            browserProfilesEnabled: true
        )
        let result = try await resolver.resolve(
            ProfileResolutionContext(bundleIdentifier: "com.apple.Safari"),
            using: StubHostnameProvider(hostname: BrowserHostname("docs.notion.so/private/page"))
        )

        #expect(result.profile.id == "notion")
        #expect(result.source == .hostname)
        #expect(
            resolver.approvedHostnameDomains == [
                "app.slack.com",
                "chatgpt.com",
                "claude.ai",
                "linear.app",
                "mail.google.com",
                "notion.so",
            ]
        )
    }
}

private struct StubHostnameProvider: BrowserHostnameProviding {
    let hostname: BrowserHostname?

    func hostname(for request: BrowserHostnameRequest) async throws -> BrowserHostname? {
        #expect(request.approvedDomains.allSatisfy { !$0.contains("/") })
        return hostname
    }
}
