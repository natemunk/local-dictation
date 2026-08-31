import Foundation

/// A normalized browser hostname. The original URL, path, query, and fragment
/// are deliberately discarded at construction time.
struct BrowserHostname: Equatable, Hashable, Sendable {
    let value: String

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: candidate)?.host,
              let normalized = Self.normalize(host)
        else {
            return nil
        }

        value = normalized
    }

    static func approvedDomain(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("://"),
              !trimmed.contains("/"),
              !trimmed.contains("?"),
              !trimmed.contains("#"),
              !trimmed.contains(":")
        else {
            return nil
        }

        return normalize(trimmed)
    }

    private static func normalize(_ hostname: String) -> String? {
        let normalized = hostname
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalized.isEmpty, normalized.count <= 253 else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return nil }

        for label in labels {
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-",
                  label.unicodeScalars.allSatisfy({ allowed.contains($0) })
            else {
                return nil
            }
        }

        return normalized
    }
}

struct ProfileResolutionContext: Equatable, Sendable {
    var bundleIdentifier: String?
    var accessibilityRole: String?
    var accessibilitySubrole: String?
    var browserHostname: BrowserHostname?

    init(
        bundleIdentifier: String?,
        accessibilityRole: String? = nil,
        accessibilitySubrole: String? = nil,
        browserHostname: BrowserHostname? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.accessibilityRole = accessibilityRole
        self.accessibilitySubrole = accessibilitySubrole
        self.browserHostname = browserHostname
    }
}

struct BrowserHostnameRequest: Equatable, Sendable {
    let browserBundleIdentifier: String
    let approvedDomains: [String]
}

/// The platform-specific browser permission/automation adapter belongs outside
/// profile resolution. Implementations return only a hostname, never a URL.
protocol BrowserHostnameProviding: Sendable {
    func hostname(for request: BrowserHostnameRequest) async throws -> BrowserHostname?
}

enum ProfileMatchSource: String, Equatable, Sendable {
    case bundleIdentifier
    case hostname
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
    let browserProfilesEnabled: Bool

    /// Source-compatible alias for integrations using the original name.
    var hostnameMatchingEnabled: Bool { browserProfilesEnabled }

    init(
        catalog: ProfileCatalog,
        defaultProfileID: String = "default",
        browserProfilesEnabled: Bool = false
    ) {
        self.catalog = catalog
        self.defaultProfileID = defaultProfileID
        self.browserProfilesEnabled = browserProfilesEnabled
    }

    init(
        catalog: ProfileCatalog,
        defaultProfileID: String = "default",
        hostnameMatchingEnabled: Bool
    ) {
        self.init(
            catalog: catalog,
            defaultProfileID: defaultProfileID,
            browserProfilesEnabled: hostnameMatchingEnabled
        )
    }

    var approvedHostnameDomains: [String] {
        Array(
            Set(
                catalog.profiles.values
                    .flatMap(\.match.hostnames)
                    .compactMap(BrowserHostname.approvedDomain(from:))
            )
        ).sorted()
    }

    func resolve(_ context: ProfileResolutionContext) -> ResolvedProfile {
        let browserContext = context.bundleIdentifier.map(isBrowserBundleIdentifier) ?? false
        var best: Candidate?

        for profile in catalog.profiles.values where profile.id != defaultProfileID {
            guard let candidate = candidate(
                for: profile,
                context: context,
                isBrowserContext: browserContext
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

    func resolve(
        _ context: ProfileResolutionContext,
        using hostnameProvider: any BrowserHostnameProviding
    ) async throws -> ResolvedProfile {
        guard browserProfilesEnabled,
              context.browserHostname == nil,
              let bundleIdentifier = context.bundleIdentifier,
              isBrowserBundleIdentifier(bundleIdentifier),
              !approvedHostnameDomains.isEmpty
        else {
            return resolve(context)
        }

        let request = BrowserHostnameRequest(
            browserBundleIdentifier: bundleIdentifier,
            approvedDomains: approvedHostnameDomains
        )
        var enriched = context
        enriched.browserHostname = try await hostnameProvider.hostname(for: request)
        return resolve(enriched)
    }

    private func candidate(
        for profile: DictationProfile,
        context: ProfileResolutionContext,
        isBrowserContext: Bool
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

        if browserProfilesEnabled,
           isBrowserContext,
           let hostname = context.browserHostname,
           match.hostnames.contains(where: { hostnameMatches(hostname.value, approvedDomain: $0) })
        {
            return Candidate(
                profile: profile,
                source: .hostname,
                score: MatchScore(identityWeight: 300, accessibilitySpecificity: roleSpecificity)
            )
        }

        if match.bundleIdentifiers.isEmpty,
           match.hostnames.isEmpty,
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

    private func isBrowserBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        catalog.profiles.values.contains { profile in
            profile.match.isGenericBrowser
                && matches(bundleIdentifier, anyOf: profile.match.bundleIdentifiers)
        }
    }

    private func matches(_ value: String?, anyOf candidates: [String]) -> Bool {
        guard let value else { return false }
        return candidates.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    private func hostnameMatches(_ hostname: String, approvedDomain: String) -> Bool {
        guard let domain = BrowserHostname.approvedDomain(from: approvedDomain) else {
            return false
        }
        return hostname == domain || hostname.hasSuffix(".\(domain)")
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
