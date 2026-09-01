import Darwin
import Foundation

enum ConfigurationDiagnosticKind: String, Equatable, Sendable {
    case fileSystem
    case parse
    case decode
    case validation
    case legacyIgnored = "legacy_ignored"
}

struct ConfigurationDiagnostic: Equatable, Sendable {
    let kind: ConfigurationDiagnosticKind
    let fileURL: URL?
    let message: String
}

struct ConfigurationReloadResult: Equatable, Sendable {
    let applied: Bool
    let snapshot: ConfigurationSnapshot
    let diagnostic: ConfigurationDiagnostic?
    let notices: [ConfigurationDiagnostic]
}

/// Owns a transactional, last-known-good configuration snapshot.
///
/// Every file is parsed and validated before `snapshot` changes. A malformed
/// edit in any file therefore cannot partially apply unrelated edits.
final class ConfigurationStore {
    let paths: ConfigurationPaths
    private(set) var snapshot: ConfigurationSnapshot
    private(set) var generation: UInt64 = 0
    private(set) var currentDiagnostic: ConfigurationDiagnostic?
    private(set) var currentNotices: [ConfigurationDiagnostic] = []
    private(set) var diagnosticHistory: [ConfigurationDiagnostic] = []

    private let fileManager: FileManager
    private let typedDefaults: ConfigurationSnapshot
    private var compiledVocabularyByProfileID: [String: CompiledVocabulary]

    init(
        paths: ConfigurationPaths = .userDefault,
        fileManager: FileManager = .default,
        typedDefaults: ConfigurationSnapshot = .typedDefaults
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.typedDefaults = typedDefaults
        snapshot = typedDefaults
        compiledVocabularyByProfileID = (
            try? Self.compileVocabularyByProfile(in: typedDefaults)
        ) ?? [:]
    }

    @discardableResult
    func bootstrapAndReload() -> ConfigurationReloadResult {
        do {
            try createInitialFilesIfNeeded()
        } catch {
            return reject(
                ConfigurationDiagnostic(
                    kind: .fileSystem,
                    fileURL: paths.rootDirectory,
                    message: "Could not create Local Dictation configuration: \(String(describing: error))"
                )
            )
        }
        return reload()
    }

    @discardableResult
    func reload() -> ConfigurationReloadResult {
        do {
            let loaded = try loadCandidate()
            let candidate = loaded.snapshot
            let compiled = try Self.compileVocabularyByProfile(in: candidate)
            snapshot = candidate
            compiledVocabularyByProfileID = compiled
            generation &+= 1
            currentDiagnostic = nil
            currentNotices = loaded.notices
            return ConfigurationReloadResult(
                applied: true,
                snapshot: snapshot,
                diagnostic: nil,
                notices: currentNotices
            )
        } catch let error as ConfigurationDocumentError {
            let kind: ConfigurationDiagnosticKind
            switch error.stage {
            case .read:
                kind = .fileSystem
            case .parse:
                kind = .parse
            case .decode, .encode:
                kind = .decode
            }
            return reject(
                ConfigurationDiagnostic(
                    kind: kind,
                    fileURL: error.fileURL,
                    message: error.message
                )
            )
        } catch let error as ConfigurationValidationError {
            return reject(
                ConfigurationDiagnostic(
                    kind: .validation,
                    fileURL: error.fileURL,
                    message: error.message
                )
            )
        } catch let error as CleanupVocabularyError {
            return reject(
                ConfigurationDiagnostic(
                    kind: .validation,
                    fileURL: paths.vocabularyDirectory,
                    message: error.description
                )
            )
        } catch {
            return reject(
                ConfigurationDiagnostic(
                    kind: .fileSystem,
                    fileURL: paths.rootDirectory,
                    message: String(describing: error)
                )
            )
        }
    }

    private func reject(_ diagnostic: ConfigurationDiagnostic) -> ConfigurationReloadResult {
        currentDiagnostic = diagnostic
        diagnosticHistory.append(diagnostic)
        return ConfigurationReloadResult(
            applied: false,
            snapshot: snapshot,
            diagnostic: diagnostic,
            notices: currentNotices
        )
    }

    func compiledVocabulary(forProfileID profileID: String) -> CompiledVocabulary? {
        compiledVocabularyByProfileID[profileID]
    }

    private static func compileVocabularyByProfile(
        in snapshot: ConfigurationSnapshot
    ) throws -> [String: CompiledVocabulary] {
        var compiled: [String: CompiledVocabulary] = [:]
        compiled.reserveCapacity(snapshot.profiles.profiles.count)
        for (profileID, profile) in snapshot.profiles.profiles {
            let selection = snapshot.vocabulary.selection(
                including: profile.vocabularyPackIDs
            )
            compiled[profileID] = try selection.compileForCleanup()
        }
        return compiled
    }

    private func loadCandidate() throws -> (
        snapshot: ConfigurationSnapshot,
        notices: [ConfigurationDiagnostic]
    ) {
        let appFile = try TOMLDocumentCodec.decode(AppConfigurationFile.self, from: paths.appFile)
        try validateVersion(appFile.version, fileURL: paths.appFile)
        let app: AppConfiguration
        do {
            app = try typedDefaults.app.applying(appFile)
        } catch let error as AppConfigurationMergeError {
            throw ConfigurationValidationError(fileURL: paths.appFile, message: error.message)
        }

        let profilesFile = try TOMLDocumentCodec.decode(ProfilesFile.self, from: paths.profilesFile)
        try validateVersion(profilesFile.version, fileURL: paths.profilesFile)
        let profiles = typedDefaults.profiles.applying(profilesFile)

        let globalFile = try TOMLDocumentCodec.decode(
            VocabularyFile.self,
            from: paths.globalVocabularyFile
        )
        try validateVersion(globalFile.version, fileURL: paths.globalVocabularyFile)
        var vocabulary = typedDefaults.vocabulary
        vocabulary.global = vocabulary.global.applying(globalFile)

        var packSourceURLs: [String: URL] = [:]
        for fileURL in try vocabularyPackFiles() {
            let id = fileURL.deletingPathExtension().lastPathComponent
            let file = try TOMLDocumentCodec.decode(VocabularyFile.self, from: fileURL)
            try validateVersion(file.version, fileURL: fileURL)
            let base = vocabulary.packs[id] ?? VocabularyPack(id: id)
            vocabulary.packs[id] = base.applying(file)
            packSourceURLs[id] = fileURL
        }

        let candidate = ConfigurationSnapshot(
            app: app,
            profiles: profiles,
            vocabulary: vocabulary
        )
        try validate(candidate, packSourceURLs: packSourceURLs)
        return (
            candidate,
            legacyNotices(appFile: appFile, profilesFile: profilesFile)
        )
    }

    private func legacyNotices(
        appFile: AppConfigurationFile,
        profilesFile: ProfilesFile
    ) -> [ConfigurationDiagnostic] {
        var notices: [ConfigurationDiagnostic] = []
        if appFile.browserProfilesEnabled != nil
            || appFile.hostnameMatchingEnabled != nil
        {
            notices.append(
                ConfigurationDiagnostic(
                    kind: .legacyIgnored,
                    fileURL: paths.appFile,
                    message: "Legacy browser_profiles_enabled/hostname_matching_enabled is ignored. Browsers now use bundle-ID profiles without Automation permission."
                )
            )
        }
        if appFile.historySuccessRetentionDays != nil {
            notices.append(
                ConfigurationDiagnostic(
                    kind: .legacyIgnored,
                    fileURL: paths.appFile,
                    message: "history_success_retention_days is a legacy key. Its value still applies to all history states; rename it to history_retention_days."
                )
            )
        }

        let hostnameProfiles = (profilesFile.profiles ?? [:])
            .filter { !($0.value.match?.hostnames ?? []).isEmpty }
            .map(\.key)
            .sorted()
        if !hostnameProfiles.isEmpty {
            notices.append(
                ConfigurationDiagnostic(
                    kind: .legacyIgnored,
                    fileURL: paths.profilesFile,
                    message: "Ignored legacy hostname matches for profile(s): \(hostnameProfiles.joined(separator: ", ")). Generic browser bundle matching remains active."
                )
            )
        }
        return notices
    }

    private func vocabularyPackFiles() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: paths.vocabularyPacksDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.caseInsensitiveCompare("toml") == .orderedSame }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func validate(
        _ candidate: ConfigurationSnapshot,
        packSourceURLs: [String: URL]
    ) throws {
        let app = candidate.app
        guard !app.defaultProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "default_profile must not be empty"
            )
        }
        guard candidate.profiles[app.defaultProfileID] != nil else {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "default_profile '\(app.defaultProfileID)' does not exist in profiles.toml or typed defaults"
            )
        }
        guard (0...5_000).contains(app.tapHoldThresholdMilliseconds) else {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "tap_hold_threshold_milliseconds must be between 0 and 5000"
            )
        }
        guard (1...(15 * 60)).contains(app.maximumRecordingDurationSeconds) else {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "maximum_recording_duration_seconds must be between 1 and 900; 15 minutes is the hard safety cap"
            )
        }
        guard app.refinementDeadlineSeconds.isFinite,
              app.refinementDeadlineSeconds > 0
        else {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "refinement_deadline_seconds must be a positive finite number"
            )
        }
        guard (0...3_650).contains(app.historySuccessRetentionDays) else {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "history_retention_days must be between 0 and 3650"
            )
        }
        if let model = app.refinerModel,
           model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "refiner_model must not be empty when provided"
            )
        }
        if let endpoint = app.refinerEndpoint {
            try validateRefinerEndpoint(endpoint, allowRemote: app.allowRemote)
        }
        if app.refinerEndpoint != nil || app.refinerMode == .openAICompatible {
            guard app.refinerEndpoint != nil else {
                throw ConfigurationValidationError(
                    fileURL: paths.appFile,
                    message: "refiner_mode = 'openai_compatible' requires refiner_endpoint"
                )
            }
            guard app.refinerModel != nil else {
                throw ConfigurationValidationError(
                    fileURL: paths.appFile,
                    message: "An explicit refiner_endpoint requires refiner_model"
                )
            }
        } else if app.refinerModel != nil {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "refiner_model requires refiner_endpoint"
            )
        }

        for (id, profile) in candidate.profiles.profiles {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationValidationError(
                    fileURL: paths.profilesFile,
                    message: "Profile identifiers must not be empty"
                )
            }
            guard (-10_000...10_000).contains(profile.priority) else {
                throw ConfigurationValidationError(
                    fileURL: paths.profilesFile,
                    message: "Profile '\(id)' priority must be between -10000 and 10000"
                )
            }
            if profile.match.isGenericBrowser && profile.match.bundleIdentifiers.isEmpty {
                throw ConfigurationValidationError(
                    fileURL: paths.profilesFile,
                    message: "Generic browser profile '\(id)' requires at least one bundle identifier"
                )
            }
            for packID in profile.vocabularyPackIDs where candidate.vocabulary.packs[packID] == nil {
                throw ConfigurationValidationError(
                    fileURL: paths.profilesFile,
                    message: "Profile '\(id)' references unknown vocabulary pack '\(packID)'"
                )
            }
            try validateNonempty(profile.match.bundleIdentifiers, label: "bundle identifier", profileID: id)
            try validateNonempty(profile.match.accessibilityRoles, label: "AX role", profileID: id)
            try validateNonempty(profile.match.accessibilitySubroles, label: "AX subrole", profileID: id)
        }

        try validateVocabulary(candidate.vocabulary.global, fileURL: paths.globalVocabularyFile)
        for (id, pack) in candidate.vocabulary.packs {
            try validateVocabulary(
                pack,
                fileURL: packSourceURLs[id] ?? paths.vocabularyPackFile(id: id)
            )
        }
    }

    private func validateVocabulary(_ pack: VocabularyPack, fileURL: URL) throws {
        try validateUniqueNonempty(pack.literalPhrases, label: "literal_phrases", fileURL: fileURL)
        try validateUniqueNonempty(pack.protectedTerms, label: "protected_terms", fileURL: fileURL)

        for source in pack.replacements.keys where source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigurationValidationError(
                fileURL: fileURL,
                message: "Vocabulary replacement sources must not be empty"
            )
        }

        var patternNames = Set<String>()
        for pattern in pack.patterns {
            let name = pattern.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw ConfigurationValidationError(
                    fileURL: fileURL,
                    message: "Vocabulary pattern names must not be empty"
                )
            }
            guard patternNames.insert(name.lowercased()).inserted else {
                throw ConfigurationValidationError(
                    fileURL: fileURL,
                    message: "Duplicate vocabulary pattern '\(pattern.name)'"
                )
            }
            guard !pattern.prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationValidationError(
                    fileURL: fileURL,
                    message: "Vocabulary pattern '\(pattern.name)' requires a nonempty prefix"
                )
            }
        }
    }

    private func validateUniqueNonempty(
        _ values: [String],
        label: String,
        fileURL: URL
    ) throws {
        var seen = Set<String>()
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ConfigurationValidationError(
                    fileURL: fileURL,
                    message: "\(label) entries must not be empty"
                )
            }
            guard seen.insert(trimmed.lowercased()).inserted else {
                throw ConfigurationValidationError(
                    fileURL: fileURL,
                    message: "Duplicate \(label) entry '\(value)'"
                )
            }
        }
    }

    private func validateNonempty(
        _ values: [String],
        label: String,
        profileID: String
    ) throws {
        if values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ConfigurationValidationError(
                fileURL: paths.profilesFile,
                message: "Profile '\(profileID)' contains an empty \(label)"
            )
        }
    }

    private func validateVersion(_ version: Int?, fileURL: URL) throws {
        guard version == nil || version == 1 else {
            throw ConfigurationValidationError(
                fileURL: fileURL,
                message: "Unsupported configuration version \(version!); expected version 1"
            )
        }
    }

    private func validateRefinerEndpoint(_ endpoint: URL, allowRemote: Bool) throws {
        guard let components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        let host = components.host?.lowercased(),
        !host.isEmpty,
        scheme == "http" || scheme == "https"
        else {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "refiner_endpoint must be an absolute HTTP or HTTPS URL"
            )
        }

        guard components.user == nil, components.password == nil else {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "refiner_endpoint must not contain credentials; API keys belong in Keychain"
            )
        }

        guard components.path == "/v1/chat/completions",
              components.query == nil,
              components.fragment == nil
        else {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "refiner_endpoint must end at /v1/chat/completions without a query or fragment"
            )
        }

        guard !Self.isLoopback(hostname: host) else { return }
        guard allowRemote else {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "A non-loopback refiner_endpoint requires allow_remote = true"
            )
        }
        guard scheme == "https" else {
            throw ConfigurationValidationError(
                fileURL: paths.appFile,
                message: "A remote refiner_endpoint must use HTTPS"
            )
        }
    }

    private static func isLoopback(hostname: String) -> Bool {
        let normalized = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalized == "localhost" || normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" {
            return true
        }

        let octets = normalized.split(separator: ".")
        guard octets.count == 4,
              let first = Int(octets[0]),
              octets.allSatisfy({ octet in
                  guard let value = Int(octet) else { return false }
                  return (0...255).contains(value)
              })
        else {
            return false
        }
        return first == 127
    }

    private func createInitialFilesIfNeeded() throws {
        try createDirectoryIfNeeded(paths.rootDirectory)
        try createDirectoryIfNeeded(paths.vocabularyDirectory)
        try createDirectoryIfNeeded(paths.vocabularyPacksDirectory)

        try createFileIfAbsent(at: paths.appFile, contents: InitialConfigurationFiles.app)
        try createFileIfAbsent(at: paths.profilesFile, contents: InitialConfigurationFiles.profiles)
        try createFileIfAbsent(
            at: paths.globalVocabularyFile,
            contents: InitialConfigurationFiles.globalVocabulary
        )
        try createFileIfAbsent(
            at: paths.symphonyVocabularyFile,
            contents: InitialConfigurationFiles.symphonyVocabulary
        )
    }

    private func createDirectoryIfNeeded(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ConfigurationValidationError(
                    fileURL: url,
                    message: "Expected a directory at \(url.path)"
                )
            }
            return
        }

        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func createFileIfAbsent(at url: URL, contents: String) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        if descriptor < 0 {
            let code = errno
            if code == EEXIST { return }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(contents.utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }
}

private struct ConfigurationValidationError: Error {
    let fileURL: URL?
    let message: String
}

private enum InitialConfigurationFiles {
    static let app = """
        # Local Dictation app overrides. Omit a key to keep its typed default.
        version = 1

        # default_profile = "default"
        refiner_mode = "auto"
        allow_remote = false
        refinement_deadline_seconds = 2.0
        history_retention_days = 90
        debug_audio_retention = false

        # refiner_endpoint = "http://127.0.0.1:8080/v1/chat/completions"
        # refiner_model = "local-model"
        # tap_hold_threshold_milliseconds = 350
        # May be lowered; values above the hard 15-minute safety cap are rejected.
        # maximum_recording_duration_seconds = 900
        """ + "\n"

    static let profiles = """
        # Local profile overrides are merged by profile identifier.
        version = 1

        # [profiles.slack]
        # formatting_style = "chat"
        # vocabulary_packs = ["symphony", "personal"]
        #
        # [profiles.slack.match]
        # accessibility_roles = ["AXTextArea"]
        """ + "\n"

    static let globalVocabulary = """
        # Global vocabulary overrides. The typed global defaults remain active
        # for fields omitted here.
        version = 1

        # literal_phrases = ["A personal name"]
        # protected_terms = ["A personal name"]
        #
        # [replacements]
        # "spoken form" = "WrittenForm"
        """ + "\n"

    static let symphonyVocabulary = """
        # Symphony pack overrides. Typed defaults include the common Symphony
        # product terms and the MYE- plus digits uppercase pattern.
        version = 1

        # [[patterns]]
        # name = "mye_ticket"
        # kind = "prefixed_digits"
        # prefix = "MYE-"
        # output_case = "uppercase"
        """ + "\n"
}
