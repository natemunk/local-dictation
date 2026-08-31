import Foundation

enum RefinerMode: String, Codable, CaseIterable, Sendable {
    case auto
    case deterministic
    case openAICompatible = "openai_compatible"
}

struct AppConfiguration: Equatable, Sendable {
    var defaultProfileID: String
    var browserProfilesEnabled: Bool
    var tapHoldThresholdMilliseconds: Int
    var maximumRecordingDurationSeconds: Int
    var refinerMode: RefinerMode
    var refinerEndpoint: URL?
    var refinerModel: String?
    var allowRemote: Bool
    var refinementDeadlineSeconds: Double
    var historySuccessRetentionDays: Int
    var debugAudioRetentionEnabled: Bool

    /// Source-compatible alias for the original pre-cutover property name.
    var hostnameMatchingEnabled: Bool {
        get { browserProfilesEnabled }
        set { browserProfilesEnabled = newValue }
    }

    init(
        defaultProfileID: String,
        browserProfilesEnabled: Bool,
        tapHoldThresholdMilliseconds: Int,
        maximumRecordingDurationSeconds: Int,
        refinerMode: RefinerMode = .auto,
        refinerEndpoint: URL? = nil,
        refinerModel: String? = nil,
        allowRemote: Bool = false,
        refinementDeadlineSeconds: Double = 2.0,
        historySuccessRetentionDays: Int = 90,
        debugAudioRetentionEnabled: Bool = false
    ) {
        self.defaultProfileID = defaultProfileID
        self.browserProfilesEnabled = browserProfilesEnabled
        self.tapHoldThresholdMilliseconds = tapHoldThresholdMilliseconds
        self.maximumRecordingDurationSeconds = maximumRecordingDurationSeconds
        self.refinerMode = refinerMode
        self.refinerEndpoint = refinerEndpoint
        self.refinerModel = refinerModel
        self.allowRemote = allowRemote
        self.refinementDeadlineSeconds = refinementDeadlineSeconds
        self.historySuccessRetentionDays = historySuccessRetentionDays
        self.debugAudioRetentionEnabled = debugAudioRetentionEnabled
    }

    init(
        defaultProfileID: String,
        hostnameMatchingEnabled: Bool,
        tapHoldThresholdMilliseconds: Int,
        maximumRecordingDurationSeconds: Int,
        refinerMode: RefinerMode = .auto,
        refinerEndpoint: URL? = nil,
        refinerModel: String? = nil,
        allowRemote: Bool = false,
        refinementDeadlineSeconds: Double = 2.0,
        historySuccessRetentionDays: Int = 90,
        debugAudioRetentionEnabled: Bool = false
    ) {
        self.init(
            defaultProfileID: defaultProfileID,
            browserProfilesEnabled: hostnameMatchingEnabled,
            tapHoldThresholdMilliseconds: tapHoldThresholdMilliseconds,
            maximumRecordingDurationSeconds: maximumRecordingDurationSeconds,
            refinerMode: refinerMode,
            refinerEndpoint: refinerEndpoint,
            refinerModel: refinerModel,
            allowRemote: allowRemote,
            refinementDeadlineSeconds: refinementDeadlineSeconds,
            historySuccessRetentionDays: historySuccessRetentionDays,
            debugAudioRetentionEnabled: debugAudioRetentionEnabled
        )
    }

    static let typedDefault = AppConfiguration(
        defaultProfileID: "default",
        browserProfilesEnabled: false,
        tapHoldThresholdMilliseconds: 350,
        maximumRecordingDurationSeconds: 15 * 60,
        refinerMode: .auto,
        refinerEndpoint: nil,
        refinerModel: nil,
        allowRemote: false,
        refinementDeadlineSeconds: 2.0,
        historySuccessRetentionDays: 90,
        debugAudioRetentionEnabled: false
    )
}

struct ConfigurationSnapshot: Equatable, Sendable {
    var app: AppConfiguration
    var profiles: ProfileCatalog
    var vocabulary: VocabularyCatalog

    static let typedDefaults = ConfigurationSnapshot(
        app: .typedDefault,
        profiles: .nativeDefaults,
        vocabulary: .nativeDefaults
    )
}

struct AppConfigurationFile: Codable, Equatable {
    var version: Int?
    var defaultProfileID: String?
    var browserProfilesEnabled: Bool?
    var hostnameMatchingEnabled: Bool?
    var tapHoldThresholdMilliseconds: Int?
    var maximumRecordingDurationSeconds: Int?
    var refinerMode: RefinerMode?
    var refinerEndpoint: String?
    var refinerModel: String?
    var allowRemote: Bool?
    var refinementDeadlineSeconds: Double?
    var historySuccessRetentionDays: Int?
    var debugAudioRetentionEnabled: Bool?

    init(
        version: Int? = nil,
        defaultProfileID: String? = nil,
        browserProfilesEnabled: Bool? = nil,
        hostnameMatchingEnabled: Bool? = nil,
        tapHoldThresholdMilliseconds: Int? = nil,
        maximumRecordingDurationSeconds: Int? = nil,
        refinerMode: RefinerMode? = nil,
        refinerEndpoint: String? = nil,
        refinerModel: String? = nil,
        allowRemote: Bool? = nil,
        refinementDeadlineSeconds: Double? = nil,
        historySuccessRetentionDays: Int? = nil,
        debugAudioRetentionEnabled: Bool? = nil
    ) {
        self.version = version
        self.defaultProfileID = defaultProfileID
        self.browserProfilesEnabled = browserProfilesEnabled
        self.hostnameMatchingEnabled = hostnameMatchingEnabled
        self.tapHoldThresholdMilliseconds = tapHoldThresholdMilliseconds
        self.maximumRecordingDurationSeconds = maximumRecordingDurationSeconds
        self.refinerMode = refinerMode
        self.refinerEndpoint = refinerEndpoint
        self.refinerModel = refinerModel
        self.allowRemote = allowRemote
        self.refinementDeadlineSeconds = refinementDeadlineSeconds
        self.historySuccessRetentionDays = historySuccessRetentionDays
        self.debugAudioRetentionEnabled = debugAudioRetentionEnabled
    }

    enum CodingKeys: String, CodingKey {
        case version
        case defaultProfileID = "default_profile"
        case browserProfilesEnabled = "browser_profiles_enabled"
        case hostnameMatchingEnabled = "hostname_matching_enabled"
        case tapHoldThresholdMilliseconds = "tap_hold_threshold_milliseconds"
        case maximumRecordingDurationSeconds = "maximum_recording_duration_seconds"
        case refinerMode = "refiner_mode"
        case refinerEndpoint = "refiner_endpoint"
        case refinerModel = "refiner_model"
        case allowRemote = "allow_remote"
        case refinementDeadlineSeconds = "refinement_deadline_seconds"
        case historySuccessRetentionDays = "history_success_retention_days"
        case debugAudioRetentionEnabled = "debug_audio_retention"
    }
}

extension AppConfiguration {
    func applying(_ file: AppConfigurationFile) throws -> AppConfiguration {
        var merged = self
        if let value = file.defaultProfileID { merged.defaultProfileID = value }
        if let value = file.browserProfilesEnabled {
            merged.browserProfilesEnabled = value
        } else if let legacyValue = file.hostnameMatchingEnabled {
            merged.browserProfilesEnabled = legacyValue
        }
        if let value = file.tapHoldThresholdMilliseconds {
            merged.tapHoldThresholdMilliseconds = value
        }
        if let value = file.maximumRecordingDurationSeconds {
            merged.maximumRecordingDurationSeconds = value
        }
        if let value = file.refinerMode { merged.refinerMode = value }
        if let value = file.refinerEndpoint {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let endpoint = URL(string: trimmed) else {
                throw AppConfigurationMergeError.invalidRefinerEndpoint(value)
            }
            merged.refinerEndpoint = endpoint
        }
        if let value = file.refinerModel { merged.refinerModel = value }
        if let value = file.allowRemote { merged.allowRemote = value }
        if let value = file.refinementDeadlineSeconds {
            merged.refinementDeadlineSeconds = value
        }
        if let value = file.historySuccessRetentionDays {
            merged.historySuccessRetentionDays = value
        }
        if let value = file.debugAudioRetentionEnabled {
            merged.debugAudioRetentionEnabled = value
        }
        return merged
    }
}

enum AppConfigurationMergeError: Error, Equatable {
    case invalidRefinerEndpoint(String)

    var message: String {
        switch self {
        case .invalidRefinerEndpoint(let value):
            return "refiner_endpoint '\(value)' is not a valid URL"
        }
    }
}

struct ProfilesFile: Codable, Equatable {
    var version: Int?
    var profiles: [String: ProfileFile]?

    init(version: Int? = nil, profiles: [String: ProfileFile]? = nil) {
        self.version = version
        self.profiles = profiles
    }
}

struct ProfileFile: Codable, Equatable {
    var mode: DictationMode?
    var formattingStyle: ProfileFormattingStyle?
    var cleanupEnabled: Bool?
    var vocabularyPackIDs: [String]?
    var priority: Int?
    var match: ProfileMatchFile?

    init(
        mode: DictationMode? = nil,
        formattingStyle: ProfileFormattingStyle? = nil,
        cleanupEnabled: Bool? = nil,
        vocabularyPackIDs: [String]? = nil,
        priority: Int? = nil,
        match: ProfileMatchFile? = nil
    ) {
        self.mode = mode
        self.formattingStyle = formattingStyle
        self.cleanupEnabled = cleanupEnabled
        self.vocabularyPackIDs = vocabularyPackIDs
        self.priority = priority
        self.match = match
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case formattingStyle = "formatting_style"
        case cleanupEnabled = "cleanup_enabled"
        case vocabularyPackIDs = "vocabulary_packs"
        case priority
        case match
    }
}

struct ProfileMatchFile: Codable, Equatable {
    var bundleIdentifiers: [String]?
    var accessibilityRoles: [String]?
    var accessibilitySubroles: [String]?
    var hostnames: [String]?
    var isGenericBrowser: Bool?

    init(
        bundleIdentifiers: [String]? = nil,
        accessibilityRoles: [String]? = nil,
        accessibilitySubroles: [String]? = nil,
        hostnames: [String]? = nil,
        isGenericBrowser: Bool? = nil
    ) {
        self.bundleIdentifiers = bundleIdentifiers
        self.accessibilityRoles = accessibilityRoles
        self.accessibilitySubroles = accessibilitySubroles
        self.hostnames = hostnames
        self.isGenericBrowser = isGenericBrowser
    }

    enum CodingKeys: String, CodingKey {
        case bundleIdentifiers = "bundle_identifiers"
        case accessibilityRoles = "accessibility_roles"
        case accessibilitySubroles = "accessibility_subroles"
        case hostnames
        case isGenericBrowser = "generic_browser"
    }
}

extension ProfileCatalog {
    func applying(_ file: ProfilesFile) -> ProfileCatalog {
        guard let overrides = file.profiles else { return self }
        var merged = self

        for (id, local) in overrides {
            let fallback = profiles["default"] ?? ProfileCatalog.nativeDefaults["default"]!
            var profile = profiles[id] ?? DictationProfile(
                id: id,
                mode: fallback.mode,
                formattingStyle: fallback.formattingStyle,
                cleanupEnabled: fallback.cleanupEnabled,
                vocabularyPackIDs: fallback.vocabularyPackIDs
            )

            if let value = local.mode { profile.mode = value }
            if let value = local.formattingStyle { profile.formattingStyle = value }
            if let value = local.cleanupEnabled { profile.cleanupEnabled = value }
            if let value = local.vocabularyPackIDs { profile.vocabularyPackIDs = value }
            if let value = local.priority { profile.priority = value }
            if let value = local.match { profile.match.apply(value) }
            merged.profiles[id] = profile
        }

        return merged
    }
}

private extension ProfileMatch {
    mutating func apply(_ file: ProfileMatchFile) {
        if let value = file.bundleIdentifiers { bundleIdentifiers = value }
        if let value = file.accessibilityRoles { accessibilityRoles = value }
        if let value = file.accessibilitySubroles { accessibilitySubroles = value }
        if let value = file.hostnames { hostnames = value }
        if let value = file.isGenericBrowser { isGenericBrowser = value }
    }
}
