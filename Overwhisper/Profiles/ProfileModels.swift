import Foundation

enum ProfileFormattingStyle: String, Codable, CaseIterable, Sendable {
    case prose
    case chat
    case structured
    case terminal
    case plain
}

struct ProfileMatch: Equatable, Sendable {
    var bundleIdentifiers: [String]
    var accessibilityRoles: [String]
    var accessibilitySubroles: [String]
    var isGenericBrowser: Bool

    init(
        bundleIdentifiers: [String] = [],
        accessibilityRoles: [String] = [],
        accessibilitySubroles: [String] = [],
        isGenericBrowser: Bool = false
    ) {
        self.bundleIdentifiers = bundleIdentifiers
        self.accessibilityRoles = accessibilityRoles
        self.accessibilitySubroles = accessibilitySubroles
        self.isGenericBrowser = isGenericBrowser
    }

    var hasAccessibilityConstraint: Bool {
        !accessibilityRoles.isEmpty || !accessibilitySubroles.isEmpty
    }

    var isEmpty: Bool {
        bundleIdentifiers.isEmpty
            && accessibilityRoles.isEmpty
            && accessibilitySubroles.isEmpty
            && !isGenericBrowser
    }
}

struct DictationProfile: Equatable, Sendable, Identifiable {
    let id: String
    var mode: DictationMode
    var formattingStyle: ProfileFormattingStyle
    var cleanupEnabled: Bool
    var vocabularyPackIDs: [String]
    var priority: Int
    var match: ProfileMatch

    init(
        id: String,
        mode: DictationMode,
        formattingStyle: ProfileFormattingStyle,
        cleanupEnabled: Bool,
        vocabularyPackIDs: [String] = [],
        priority: Int = 0,
        match: ProfileMatch = ProfileMatch()
    ) {
        self.id = id
        self.mode = mode
        self.formattingStyle = formattingStyle
        self.cleanupEnabled = cleanupEnabled
        self.vocabularyPackIDs = vocabularyPackIDs
        self.priority = priority
        self.match = match
    }
}

struct ProfileCatalog: Equatable, Sendable {
    var profiles: [String: DictationProfile]

    init(profiles: [String: DictationProfile]) {
        self.profiles = profiles
    }

    subscript(id: String) -> DictationProfile? {
        profiles[id]
    }
}

enum TerminalProfilePolicy {
    static func enforcingSafety(on profile: DictationProfile) -> DictationProfile {
        var profile = profile
        profile.mode = .literal
        profile.formattingStyle = .terminal
        profile.cleanupEnabled = false
        return profile
    }
}
