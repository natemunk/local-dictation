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

        let restored = AppState(preferences: defaults)
        #expect(restored.overlayPosition == .topRight)
        #expect(restored.selectedInputDeviceUID == "test-microphone")
        #expect(restored.asrSelection == .whisperLargeV3Turbo)
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
        #expect(!state.onboardingReady)

        state.microphonePermissionGranted = true
        state.inputMonitoringGranted = true
        state.accessibilityGranted = true
        state.hotkeyMonitoringActive = true
        #expect(!state.onboardingReady)

        state.engineReady = true
        #expect(state.onboardingReady)

        state.hotkeyMonitoringActive = false
        #expect(!state.onboardingReady)
    }
}
