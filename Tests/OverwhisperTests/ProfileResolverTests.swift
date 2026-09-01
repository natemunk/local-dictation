import Testing
@testable import LocalDictation

@Suite("Profile resolution")
struct ProfileResolverTests {
    @Test("native app defaults resolve by bundle identifier")
    func nativeAppDefaults() {
        let resolver = ProfileResolver(catalog: .nativeDefaults)
        let cases = [
            ("com.mitchellh.ghostty", "terminal"),
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

    @Test("generic browsers resolve only by bundle identifier")
    func genericBrowserBundleFallback() {
        let resolver = ProfileResolver(catalog: .nativeDefaults)

        let chrome = resolver.resolve(
            ProfileResolutionContext(bundleIdentifier: "com.google.Chrome")
        )
        #expect(chrome.profile.id == "browser")
        #expect(chrome.source == .genericBrowser)

        let lookalike = resolver.resolve(
            ProfileResolutionContext(bundleIdentifier: "com.google.Chrome.helper")
        )
        #expect(lookalike.profile.id == "default")
        #expect(lookalike.source == .defaultProfile)
    }
}
