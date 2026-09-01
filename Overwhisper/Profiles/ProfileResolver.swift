import Foundation

struct ProfileResolutionContext: Equatable, Sendable {
    var bundleIdentifier: String?
    var accessibilityRole: String?
    var accessibilitySubrole: String?

    init(
        bundleIdentifier: String?,
        accessibilityRole: String? = nil,
        accessibilitySubrole: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.accessibilityRole = accessibilityRole
        self.accessibilitySubrole = accessibilitySubrole
    }
}

enum ProfileMatchSource: String, Equatable, Sendable {
    case bundleIdentifier
    case accessibility
    case genericBrowser
    case defaultProfile
}

struct ResolvedProfile: Equatable, Sendable {
    let profile: DictationProfile
    let source: ProfileMatchSource
}

struct ProfileResolver: Sendable {
    let catalog: ProfileCatalog
    let defaultProfileID: String

    init(
        catalog: ProfileCatalog,
        defaultProfileID: String = "default"
    ) {
        self.catalog = catalog
        self.defaultProfileID = defaultProfileID
    }

    func resolve(_ context: ProfileResolutionContext) -> ResolvedProfile {
        var best: Candidate?

        for profile in catalog.profiles.values where profile.id != defaultProfileID {
            guard let candidate = candidate(
                for: profile,
                context: context
            ) else {
                continue
            }

            if candidate.isPreferred(over: best) {
                best = candidate
            }
        }

        if let best {
            return ResolvedProfile(profile: best.profile, source: best.source)
        }

        let fallback = catalog[defaultProfileID]
            ?? catalog["default"]
            ?? ProfileCatalog.nativeDefaults["default"]!
        return ResolvedProfile(profile: fallback, source: .defaultProfile)
    }

    private func candidate(
        for profile: DictationProfile,
        context: ProfileResolutionContext
    ) -> Candidate? {
        let match = profile.match
        guard !match.isEmpty else { return nil }

        let roleSpecificity = accessibilitySpecificity(match: match, context: context)
        guard roleSpecificity >= 0 else { return nil }

        if matches(context.bundleIdentifier, anyOf: match.bundleIdentifiers) {
            let source: ProfileMatchSource = match.isGenericBrowser
                ? .genericBrowser
                : .bundleIdentifier
            let identityWeight = match.isGenericBrowser ? 100 : 400
            return Candidate(
                profile: profile,
                source: source,
                score: MatchScore(identityWeight: identityWeight, accessibilitySpecificity: roleSpecificity)
            )
        }

        if match.bundleIdentifiers.isEmpty,
           match.hasAccessibilityConstraint
        {
            return Candidate(
                profile: profile,
                source: .accessibility,
                score: MatchScore(identityWeight: 200, accessibilitySpecificity: roleSpecificity)
            )
        }

        return nil
    }

    private func accessibilitySpecificity(
        match: ProfileMatch,
        context: ProfileResolutionContext
    ) -> Int {
        var specificity = 0

        if !match.accessibilityRoles.isEmpty {
            guard matches(context.accessibilityRole, anyOf: match.accessibilityRoles) else {
                return -1
            }
            specificity += 2
        }

        if !match.accessibilitySubroles.isEmpty {
            guard matches(context.accessibilitySubrole, anyOf: match.accessibilitySubroles) else {
                return -1
            }
            specificity += 1
        }

        return specificity
    }

    private func matches(_ value: String?, anyOf candidates: [String]) -> Bool {
        guard let value else { return false }
        return candidates.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }
}

private struct MatchScore: Comparable {
    let identityWeight: Int
    let accessibilitySpecificity: Int

    static func < (lhs: MatchScore, rhs: MatchScore) -> Bool {
        if lhs.identityWeight != rhs.identityWeight {
            return lhs.identityWeight < rhs.identityWeight
        }
        return lhs.accessibilitySpecificity < rhs.accessibilitySpecificity
    }
}

private struct Candidate {
    let profile: DictationProfile
    let source: ProfileMatchSource
    let score: MatchScore

    func isPreferred(over other: Candidate?) -> Bool {
        guard let other else { return true }
        if score != other.score { return score > other.score }
        if profile.priority != other.profile.priority {
            return profile.priority > other.profile.priority
        }
        return profile.id < other.profile.id
    }
}
