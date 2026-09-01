import Foundation

extension ProfileCatalog {
    static let nativeDefaults: ProfileCatalog = {
        let profiles = [
            DictationProfile(
                id: "terminal",
                mode: .literal,
                formattingStyle: .terminal,
                cleanupEnabled: false,
                vocabularyPackIDs: ["symphony"],
                match: ProfileMatch(
                    bundleIdentifiers: [
                        "com.mitchellh.ghostty",
                        "com.apple.Terminal",
                        "com.googlecode.iterm2",
                        "dev.warp.Warp",
                        "dev.warp.Warp-Stable",
                    ]
                )
            ),
            DictationProfile(
                id: "ghostty",
                mode: .literal,
                formattingStyle: .terminal,
                cleanupEnabled: false,
                vocabularyPackIDs: ["symphony"],
                match: ProfileMatch(bundleIdentifiers: ["com.mitchellh.ghostty"])
            ),
            DictationProfile(
                id: "slack",
                mode: .clean,
                formattingStyle: .chat,
                cleanupEnabled: true,
                vocabularyPackIDs: ["symphony"],
                match: ProfileMatch(
                    bundleIdentifiers: ["com.tinyspeck.slackmacgap"],
                    hostnames: ["app.slack.com"]
                )
            ),
            DictationProfile(
                id: "linear",
                mode: .clean,
                formattingStyle: .structured,
                cleanupEnabled: true,
                vocabularyPackIDs: ["symphony"],
                match: ProfileMatch(
                    bundleIdentifiers: ["com.linear"],
                    hostnames: ["linear.app"]
                )
            ),
            DictationProfile(
                id: "notes",
                mode: .clean,
                formattingStyle: .prose,
                cleanupEnabled: true,
                match: ProfileMatch(bundleIdentifiers: ["com.apple.Notes"])
            ),
            DictationProfile(
                id: "notion",
                mode: .clean,
                formattingStyle: .structured,
                cleanupEnabled: true,
                match: ProfileMatch(
                    bundleIdentifiers: ["notion.id", "com.notion.id"],
                    hostnames: ["notion.so"]
                )
            ),
            DictationProfile(
                id: "chatgpt-web",
                mode: .clean,
                formattingStyle: .structured,
                cleanupEnabled: true,
                vocabularyPackIDs: ["symphony"],
                match: ProfileMatch(hostnames: ["chatgpt.com"])
            ),
            DictationProfile(
                id: "claude-web",
                mode: .clean,
                formattingStyle: .structured,
                cleanupEnabled: true,
                vocabularyPackIDs: ["symphony"],
                match: ProfileMatch(hostnames: ["claude.ai"])
            ),
            DictationProfile(
                id: "gmail-web",
                mode: .clean,
                formattingStyle: .prose,
                cleanupEnabled: true,
                match: ProfileMatch(hostnames: ["mail.google.com"])
            ),
            DictationProfile(
                id: "browser",
                mode: .clean,
                formattingStyle: .prose,
                cleanupEnabled: true,
                match: ProfileMatch(
                    bundleIdentifiers: [
                        "com.apple.Safari",
                        "com.google.Chrome",
                        "com.brave.Browser",
                        "com.microsoft.edgemac",
                        "company.thebrowser.Browser",
                        "org.mozilla.firefox",
                    ],
                    isGenericBrowser: true
                )
            ),
            DictationProfile(
                id: "default",
                mode: .clean,
                formattingStyle: .prose,
                cleanupEnabled: true
            ),
        ]

        return ProfileCatalog(
            profiles: Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        )
    }()
}
