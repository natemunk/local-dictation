import Foundation
import Testing
@testable import LocalDictation

@Suite("App settings persistence", .serialized)
struct AppStatePreferencesTests {
    @Test("user-selected settings survive a fresh AppState")
    @MainActor
    func settingsRoundTrip() throws {
        let suiteName = "AppStatePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppState(preferences: defaults)
        first.overlayPosition = .topRight
        first.selectedInputDeviceUID = "test-microphone"
        first.asrSelection = .whisperLargeV3Turbo
        first.privateClipboardMode = true
        first.experimentalModelCleanupEnabled = true

        let restored = AppState(preferences: defaults)
        #expect(restored.overlayPosition == .topRight)
        #expect(restored.selectedInputDeviceUID == "test-microphone")
        #expect(restored.asrSelection == .whisperLargeV3Turbo)
        #expect(restored.privateClipboardMode)
        #expect(restored.experimentalModelCleanupEnabled)
    }

    @Test("unknown persisted values fall back to safe defaults")
    @MainActor
    func invalidValuesUseDefaults() throws {
        let suiteName = "AppStatePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("sideways", forKey: LocalDictationPreferenceKey.overlayPosition)
        defaults.set("cloud", forKey: LocalDictationPreferenceKey.asrSelection)

        let state = AppState(preferences: defaults)
        #expect(state.overlayPosition == .bottomCenter)
        #expect(state.asrSelection == .parakeetV2)
        #expect(!state.experimentalModelCleanupEnabled)
    }

    @Test("Keychain identity is constant and legacy migration writes before deleting")
    func keychainMigrationIsScopedAndOrdered() throws {
        #expect(KeychainStore.service == "com.natemunk.LocalDictation")

        let account = LocalDictationKeychainAccount.openAICompatibleRefiner
        var values = ["legacy.dev": "secret"]
        var events: [String] = []
        let value = KeychainStore.migrateValue(
            account: account,
            legacyServices: ["legacy.dev"],
            read: { values["\($0)|\($1)"] ?? values[$0] },
            write: { value, service, account in
                events.append("write:\(service):\(account)")
                values["\(service)|\(account)"] = value
            },
            delete: { service, account in
                events.append("delete:\(service):\(account)")
                values.removeValue(forKey: service)
            }
        )

        #expect(value == "secret")
        #expect(events == [
            "write:com.natemunk.LocalDictation:\(account)",
            "delete:legacy.dev:\(account)",
        ])
        #expect(values["com.natemunk.LocalDictation|\(account)"] == "secret")
        #expect(values["legacy.dev"] == nil)
    }

    @Test("a failed Keychain migration never deletes the legacy item")
    func failedKeychainMigrationPreservesLegacy() {
        struct WriteFailure: Error {}
        var deleted = false

        do {
            _ = try KeychainStore.migrateValue(
                account: "refiner",
                legacyServices: ["legacy.dev"],
                read: { service, _ in service == "legacy.dev" ? "secret" : nil },
                write: { _, _, _ in throw WriteFailure() },
                delete: { _, _ in deleted = true }
            )
            Issue.record("Expected the migration write to fail")
        } catch is WriteFailure {
            #expect(!deleted)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("legacy engine and model preferences migrate once")
    @MainActor
    func legacySelectionMigrates() throws {
        let suiteName = "AppStatePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            TranscriptionEngineType.whisperKit.rawValue,
            forKey: LocalDictationPreferenceKey.transcriptionEngine
        )
        defaults.set(
            WhisperModel.largeV3Turbo.rawValue,
            forKey: LocalDictationPreferenceKey.whisperModel
        )

        let migrated = AppState(preferences: defaults)
        #expect(migrated.asrSelection == .whisperLargeV3Turbo)
        #expect(
            defaults.string(forKey: LocalDictationPreferenceKey.asrSelection)
                == ASRSelection.whisperLargeV3Turbo.rawValue
        )
    }

    @Test("onboarding readiness requires permissions tap health and a prepared engine")
    @MainActor
    func onboardingReadinessRequiresEveryGate() throws {
        let suiteName = "AppStatePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState(preferences: defaults)
        #expect(!state.basePermissionsReady)
        #expect(!state.onboardingReady)

        state.microphonePermissionGranted = true
        state.inputMonitoringGranted = true
        state.accessibilityGranted = true
        #expect(state.basePermissionsReady)
        state.hotkeyMonitoringActive = true
        #expect(!state.onboardingReady)

        state.engineReady = true
        #expect(state.onboardingReady)

        state.hotkeyMonitoringActive = false
        #expect(!state.onboardingReady)
    }
}
