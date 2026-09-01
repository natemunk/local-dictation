import Foundation
import Testing
@testable import LocalDictation

@Suite("Local Dictation configuration")
struct ConfigurationStoreTests {
    @Test("local TOML values win while omitted fields retain typed defaults")
    func mergePrecedence() throws {
        let temporary = try TemporaryConfigurationDirectory()
        defer { temporary.remove() }

        let paths = ConfigurationPaths(rootDirectory: temporary.url)
        let store = ConfigurationStore(paths: paths)
        #expect(store.bootstrapAndReload().applied)

        try Self.write(
            """
            version = 1
            default_profile = "notes"
            browser_profiles_enabled = true
            tap_hold_threshold_milliseconds = 425
            refiner_mode = "openai_compatible"
            refiner_endpoint = "http://127.0.0.1:11434/v1/chat/completions"
            refiner_model = "local-test-model"
            allow_remote = false
            refinement_deadline_seconds = 1.25
            history_success_retention_days = 30
            debug_audio_retention = true
            """,
            to: paths.appFile
        )
        try Self.write(
            """
            version = 1

            [profiles.slack]
            mode = "literal"
            priority = 25

            [profiles.slack.match]
            bundle_identifiers = ["com.example.LocalSlack"]
            accessibility_roles = ["AXTextArea"]

            [profiles.focused_editor]
            mode = "clean"
            formatting_style = "plain"
            cleanup_enabled = false

            [profiles.focused_editor.match]
            accessibility_roles = ["AXTextArea"]
            accessibility_subroles = ["AXStandardTextArea"]
            """,
            to: paths.profilesFile
        )
        try Self.write(
            """
            version = 1
            literal_phrases = ["Personal Global"]

            [replacements]
            "local dictation" = "LD"
            """,
            to: paths.globalVocabularyFile
        )
        try Self.write(
            """
            version = 1

            [replacements]
            "my educator" = "MyEducator Local"
            """,
            to: paths.symphonyVocabularyFile
        )

        let result = store.reload()

        #expect(result.applied)
        #expect(result.snapshot.app.defaultProfileID == "notes")
        #expect(!result.snapshot.app.browserProfilesEnabled)
        #expect(!result.snapshot.app.hostnameMatchingEnabled)
        #expect(result.notices.contains { $0.kind == .legacyIgnored })
        #expect(result.snapshot.app.tapHoldThresholdMilliseconds == 425)
        #expect(result.snapshot.app.maximumRecordingDurationSeconds == 900)
        #expect(result.snapshot.app.refinerMode == .openAICompatible)
        #expect(result.snapshot.app.refinerEndpoint?.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
        #expect(result.snapshot.app.refinerModel == "local-test-model")
        #expect(!result.snapshot.app.allowRemote)
        #expect(result.snapshot.app.refinementDeadlineSeconds == 1.25)
        #expect(result.snapshot.app.historySuccessRetentionDays == 30)
        #expect(result.snapshot.app.debugAudioRetentionEnabled)

        let slack = try #require(result.snapshot.profiles["slack"])
        #expect(slack.mode == .literal)
        #expect(slack.formattingStyle == .prose)
        #expect(slack.priority == 25)
        #expect(slack.match.bundleIdentifiers == ["com.example.LocalSlack"])
        #expect(slack.match.accessibilityRoles == ["AXTextArea"])

        let custom = try #require(result.snapshot.profiles["focused_editor"])
        #expect(custom.formattingStyle == .plain)
        #expect(!custom.cleanupEnabled)

        #expect(result.snapshot.vocabulary.global.literalPhrases == ["Personal Global"])
        #expect(result.snapshot.vocabulary.global.protectedTerms == ["Local Dictation"])
        #expect(result.snapshot.vocabulary.global.replacements["local dictation"] == "LD")

        let symphony = try #require(result.snapshot.vocabulary.packs["symphony"])
        #expect(symphony.replacements["my educator"] == "MyEducator Local")
        #expect(symphony.replacements["open router"] == "OpenRouter")
        #expect(symphony.patterns.contains { $0.name == "mye_ticket" })
    }

    @Test("browser hostname settings are absent from fresh defaults")
    func hostnameSettingsAreLegacyOnly() throws {
        let temporary = try TemporaryConfigurationDirectory()
        defer { temporary.remove() }

        let paths = ConfigurationPaths(rootDirectory: temporary.url)
        let store = ConfigurationStore(paths: paths)
        let result = store.bootstrapAndReload()

        #expect(result.applied)
        let defaults = ConfigurationSnapshot.typedDefaults.app
        #expect(!defaults.browserProfilesEnabled)
        #expect(!defaults.hostnameMatchingEnabled)
        #expect(defaults.refinerMode == .auto)
        #expect(defaults.refinerEndpoint == nil)
        #expect(defaults.refinerModel == nil)
        #expect(!defaults.allowRemote)
        #expect(defaults.refinementDeadlineSeconds == 2.0)
        #expect(defaults.historySuccessRetentionDays == 90)
        #expect(!defaults.debugAudioRetentionEnabled)

        #expect(!result.snapshot.app.browserProfilesEnabled)
        let generated = try String(contentsOf: paths.appFile, encoding: .utf8)
        #expect(!generated.contains("browser_profiles_enabled"))
        #expect(!generated.contains("hostname_matching_enabled"))
        #expect(generated.contains("refiner_mode = \"auto\""))
        #expect(generated.contains("allow_remote = false"))
        #expect(generated.contains("refinement_deadline_seconds = 2.0"))
        #expect(generated.contains("history_retention_days = 90"))
        #expect(!generated.contains("history_success_retention_days"))
        #expect(generated.contains("debug_audio_retention = false"))
        #expect(!generated.lowercased().contains("api_key"))
    }

    @Test("legacy hostname settings are ignored with a nonfatal notice")
    func legacyHostnameSettingsAreIgnored() throws {
        let temporary = try TemporaryConfigurationDirectory()
        defer { temporary.remove() }
        let paths = ConfigurationPaths(rootDirectory: temporary.url)
        let store = ConfigurationStore(paths: paths)
        #expect(store.bootstrapAndReload().applied)

        try Self.write(
            """
            version = 1
            browser_profiles_enabled = true
            hostname_matching_enabled = true
            """,
            to: paths.appFile
        )
        try Self.write(
            """
            version = 1

            [profiles.legacy_browser]
            mode = "clean"

            [profiles.legacy_browser.match]
            bundle_identifiers = ["com.google.Chrome"]
            hostnames = ["https://bad.example/private/path"]
            """,
            to: paths.profilesFile
        )

        let result = store.reload()

        #expect(result.applied)
        #expect(!result.snapshot.app.browserProfilesEnabled)
        #expect(result.notices.count == 2)
        #expect(result.notices.allSatisfy { $0.kind == .legacyIgnored })
        let legacy = try #require(result.snapshot.profiles["legacy_browser"])
        #expect(legacy.match.bundleIdentifiers == ["com.google.Chrome"])
        #expect(store.currentNotices == result.notices)
    }

    @Test("remote refiner endpoints require opt-in and HTTPS while loopback HTTP remains local")
    func refinerEndpointValidation() throws {
        let temporary = try TemporaryConfigurationDirectory()
        defer { temporary.remove() }

        let paths = ConfigurationPaths(rootDirectory: temporary.url)
        let store = ConfigurationStore(paths: paths)
        #expect(store.bootstrapAndReload().applied)
        let lastKnownGood = store.snapshot

        try Self.write(
            """
            version = 1
            refiner_endpoint = "https://api.example.com/v1/chat/completions"
            refiner_model = "test-model"
            allow_remote = false
            """,
            to: paths.appFile
        )
        let missingOptIn = store.reload()
        #expect(!missingOptIn.applied)
        #expect(missingOptIn.snapshot == lastKnownGood)
        #expect(missingOptIn.diagnostic?.message.contains("allow_remote = true") == true)

        try Self.write(
            """
            version = 1
            refiner_endpoint = "http://api.example.com/v1/chat/completions"
            refiner_model = "test-model"
            allow_remote = true
            """,
            to: paths.appFile
        )
        let insecureRemote = store.reload()
        #expect(!insecureRemote.applied)
        #expect(insecureRemote.snapshot == lastKnownGood)
        #expect(insecureRemote.diagnostic?.message.contains("must use HTTPS") == true)

        try Self.write(
            """
            version = 1
            refiner_endpoint = "https://api.example.com/v1/chat/completions"
            refiner_model = "test-model"
            allow_remote = true
            """,
            to: paths.appFile
        )
        let approvedRemote = store.reload()
        #expect(approvedRemote.applied)
        #expect(approvedRemote.snapshot.app.allowRemote)
        #expect(approvedRemote.snapshot.app.refinerEndpoint?.host == "api.example.com")

        try Self.write(
            """
            version = 1
            refiner_endpoint = "http://localhost:8080/v1/chat/completions"
            refiner_model = "test-model"
            allow_remote = false
            """,
            to: paths.appFile
        )
        let local = store.reload()
        #expect(local.applied)
        #expect(local.snapshot.app.refinerEndpoint?.host == "localhost")
        #expect(!local.snapshot.app.allowRemote)
    }

    @Test("invalid reload retains the complete last-known-good snapshot and reports its file")
    func invalidReloadPreservesLastKnownGood() throws {
        let temporary = try TemporaryConfigurationDirectory()
        defer { temporary.remove() }

        let paths = ConfigurationPaths(rootDirectory: temporary.url)
        let store = ConfigurationStore(paths: paths)
        #expect(store.bootstrapAndReload().applied)

        try Self.write(
            """
            version = 1
            default_profile = "notes"
            """,
            to: paths.appFile
        )
        let valid = store.reload()
        #expect(valid.applied)
        let lastKnownGood = valid.snapshot

        try Self.write(
            """
            version = 1
            maximum_recording_duration_seconds = 901
            """,
            to: paths.appFile
        )
        let unsafeDuration = store.reload()
        #expect(!unsafeDuration.applied)
        #expect(unsafeDuration.snapshot == lastKnownGood)
        #expect(unsafeDuration.diagnostic?.kind == .validation)
        #expect(unsafeDuration.diagnostic?.message.contains("hard safety cap") == true)

        try Self.write("default_profile = [\n", to: paths.appFile)
        let rejected = store.reload()

        #expect(!rejected.applied)
        #expect(rejected.snapshot == lastKnownGood)
        #expect(store.snapshot == lastKnownGood)
        #expect(rejected.diagnostic?.kind == .parse)
        #expect(rejected.diagnostic?.fileURL == paths.appFile)
        #expect(store.diagnosticHistory.count == 2)

        try Self.write(
            """
            version = 1
            default_profile = "slack"
            """,
            to: paths.appFile
        )
        let repaired = store.reload()
        #expect(repaired.applied)
        #expect(repaired.snapshot.app.defaultProfileID == "slack")
        #expect(store.currentDiagnostic == nil)
    }

    @Test("bootstrap creates missing files without replacing an existing edit")
    func safeInitialFileCreation() throws {
        let temporary = try TemporaryConfigurationDirectory()
        defer { temporary.remove() }

        let paths = ConfigurationPaths(rootDirectory: temporary.url)
        try FileManager.default.createDirectory(
            at: paths.rootDirectory,
            withIntermediateDirectories: true
        )
        let existing = "version = 1\ndefault_profile = \"notes\"\n"
        try Self.write(existing, to: paths.appFile)

        let store = ConfigurationStore(paths: paths)
        let result = store.bootstrapAndReload()

        #expect(result.applied)
        #expect(try String(contentsOf: paths.appFile, encoding: .utf8) == existing)
        #expect(FileManager.default.fileExists(atPath: paths.profilesFile.path))
        #expect(FileManager.default.fileExists(atPath: paths.globalVocabularyFile.path))
        #expect(FileManager.default.fileExists(atPath: paths.symphonyVocabularyFile.path))
    }

    @Test("typed replacements and MYE ticket pattern are deterministic")
    func vocabularyRules() throws {
        let vocabulary = VocabularyCatalog.nativeDefaults.selection(including: ["symphony"])

        #expect(vocabulary.literalPhrases.contains("MyEducator"))
        #expect(vocabulary.protectedTerms.contains("OpenRouter"))
        #expect(
            vocabulary.applyingDeterministicRules(
                to: "Check mye-2076 in my educator, not someyeducator."
            ) == "Check MYE-2076 in MyEducator, not someyeducator."
        )
    }

    @Test("compiled vocabulary is reused within one configuration generation")
    func compiledVocabularyGeneration() throws {
        let temporary = try TemporaryConfigurationDirectory()
        defer { temporary.remove() }

        let paths = ConfigurationPaths(rootDirectory: temporary.url)
        let store = ConfigurationStore(paths: paths)
        #expect(store.bootstrapAndReload().applied)
        let firstGeneration = store.generation
        let first = try #require(store.compiledVocabulary(forProfileID: "linear"))
        let same = try #require(store.compiledVocabulary(forProfileID: "linear"))
        #expect(first.compilationID == same.compilationID)

        let normalized = try CleanupVocabularyProcessor(
            compiledVocabulary: first
        ).process("check mye-2076 in my educator")
        #expect(normalized.text == "check MYE-2076 in MyEducator")

        #expect(store.reload().applied)
        let recompiled = try #require(store.compiledVocabulary(forProfileID: "linear"))
        #expect(store.generation == firstGeneration + 1)
        #expect(recompiled.compilationID != first.compilationID)
    }

    @Test("large personal packs compile once and apply to every profile")
    func largePersonalVocabularyPack() throws {
        let temporary = try TemporaryConfigurationDirectory()
        defer { temporary.remove() }

        let paths = ConfigurationPaths(rootDirectory: temporary.url)
        let store = ConfigurationStore(paths: paths)
        #expect(store.bootstrapAndReload().applied)

        let mappings = (0..<300).map {
            "\"spoken phrase \($0)\" = \"WrittenPhrase\($0)\""
        }.joined(separator: "\n")
        try Self.write(
            "version = 1\n\n[replacements]\n\(mappings)\n",
            to: paths.personalVocabularyFile
        )

        let result = store.reload()
        #expect(result.applied)
        for profileID in ["terminal", "linear", "notes", "browser", "default"] {
            let compiled = try #require(store.compiledVocabulary(forProfileID: profileID))
            let output = try CleanupVocabularyProcessor(
                compiledVocabulary: compiled
            ).process("spoken phrase 299")
            #expect(output.text == "WrittenPhrase299")
        }
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: [.atomic])
    }
}

private struct TemporaryConfigurationDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
