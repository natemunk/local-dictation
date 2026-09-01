import Combine
import Foundation
import Security

enum MicInputStatus: Equatable, Sendable {
    case ok
    case low
    case silent
}

enum OverlayPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft = "Top Left"
    case topCenter = "Top Center"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    case bottomCenter = "Bottom Center"
    case bottomRight = "Bottom Right"

    var id: String { rawValue }
}

enum TranscriptionEngineType: String, Codable, CaseIterable, Identifiable, Sendable {
    case parakeet = "FluidAudio Parakeet"
    case whisperKit = "WhisperKit"

    var id: String { rawValue }
}

enum ParakeetModelType: String, Codable, CaseIterable, Identifiable, Sendable {
    case v2English = "parakeet-v2"
    case v3Multilingual = "parakeet-v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .v2English: "Parakeet v2 — English"
        case .v3Multilingual: "Parakeet v3 — Multilingual benchmark"
        }
    }

}

enum WhisperModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case smallEn = "small.en"
    case largeV3Turbo = "large-v3_turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .smallEn: "Small English"
        case .largeV3Turbo: "Large v3 Turbo"
        }
    }

}

struct LiveTranscript: Equatable, Sendable {
    var finalized: String = ""
    var volatile: String = ""

    var displayed: String {
        [finalized, volatile].filter { !$0.isEmpty }.joined(separator: finalized.isEmpty ? "" : " ")
    }
}

@MainActor
final class AppState: ObservableObject {
    private let preferences: UserDefaults

    @Published var phase: DictationPhase = .idle
    @Published var audioLevel: Float = 0
    @Published var recordingDuration: TimeInterval = 0
    @Published var micInputStatus: MicInputStatus = .ok
    @Published var interleavedTyping = false
    @Published var overlayMessage = "Listening"
    @Published var liveTranscript = LiveTranscript()
    @Published var isRemoteRefiner = false
    @Published var activeProfileName = "Default"

    @Published var overlayPosition: OverlayPosition {
        didSet { preferences.set(overlayPosition.rawValue, forKey: LocalDictationPreferenceKey.overlayPosition) }
    }
    @Published var selectedInputDeviceUID: String {
        didSet { preferences.set(selectedInputDeviceUID, forKey: LocalDictationPreferenceKey.selectedInputDeviceUID) }
    }
    @Published var asrSelection: ASRSelection {
        didSet {
            preferences.set(
                asrSelection.rawValue,
                forKey: LocalDictationPreferenceKey.asrSelection
            )
        }
    }
    @Published var language = "en"
    @Published var customVocabulary = ""
    @Published var raycastVocabularyImportText = ""

    @Published var modelDownloadProgress: Double = 0
    @Published var isDownloadingModel = false
    @Published var isInitializingEngine = false
    @Published var engineReady = false
    @Published var currentlyDownloadingModel: String?

    @Published var lastTranscription = ""
    @Published var lastError: String?
    @Published var configurationDiagnostic: String?
    @Published var configurationNotices: [String] = []
    @Published var microphonePermissionGranted = false
    @Published var inputMonitoringGranted = false
    @Published var accessibilityGranted = false
    @Published var hotkeyMonitoringActive = false
    @Published var hotkeyMonitoringError: String?
    @Published var hasCompletedOnboarding = false
    @Published var retainDebugAudio: Bool
    @Published var privateClipboardMode: Bool {
        didSet {
            preferences.set(
                privateClipboardMode,
                forKey: LocalDictationPreferenceKey.privateClipboardMode
            )
        }
    }
    @Published var experimentalModelCleanupEnabled: Bool {
        didSet {
            preferences.set(
                experimentalModelCleanupEnabled,
                forKey: LocalDictationPreferenceKey.experimentalModelCleanupEnabled
            )
        }
    }
    @Published var refinerAPIKey: String

    let debugSessionStore = DebugSessionStore()

    private var recordingTimer: Timer?
    private var levelWindow: [Float] = []
    private var lastAudibleAt: TimeInterval = 0
    private var hasHeardAudio = false
    private var micProvenHealthy = false

    var onboardingReady: Bool {
        microphonePermissionGranted
            && inputMonitoringGranted
            && accessibilityGranted
            && hotkeyMonitoringActive
            && engineReady
    }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        overlayPosition = preferences.string(forKey: LocalDictationPreferenceKey.overlayPosition)
            .flatMap(OverlayPosition.init(rawValue:)) ?? .bottomCenter
        selectedInputDeviceUID = preferences.string(
            forKey: LocalDictationPreferenceKey.selectedInputDeviceUID
        ) ?? ""
        if let persisted = preferences.string(forKey: LocalDictationPreferenceKey.asrSelection)
            .flatMap(ASRSelection.init(rawValue:)) {
            asrSelection = persisted
        } else {
            let migrated = Self.migratedASRSelection(from: preferences)
            asrSelection = migrated
            preferences.set(
                migrated.rawValue,
                forKey: LocalDictationPreferenceKey.asrSelection
            )
        }
        retainDebugAudio = preferences.bool(forKey: LocalDictationPreferenceKey.retainDebugAudio)
        privateClipboardMode = preferences.bool(
            forKey: LocalDictationPreferenceKey.privateClipboardMode
        )
        experimentalModelCleanupEnabled = preferences.bool(
            forKey: LocalDictationPreferenceKey.experimentalModelCleanupEnabled
        )
        refinerAPIKey = KeychainStore.loadMigratingLegacyServices(
            account: LocalDictationKeychainAccount.openAICompatibleRefiner
        ) ?? ""
    }

    private static func migratedASRSelection(from preferences: UserDefaults) -> ASRSelection {
        let family = preferences.string(forKey: LocalDictationPreferenceKey.transcriptionEngine)
            .flatMap(TranscriptionEngineType.init(rawValue:)) ?? .parakeet
        switch family {
        case .parakeet:
            let model = preferences.string(forKey: LocalDictationPreferenceKey.parakeetModel)
                .flatMap(ParakeetModelType.init(rawValue:)) ?? .v2English
            return model == .v3Multilingual ? .parakeetV3 : .parakeetV2
        case .whisperKit:
            let model = preferences.string(forKey: LocalDictationPreferenceKey.whisperModel)
                .flatMap(WhisperModel.init(rawValue:)) ?? .smallEn
            return model == .largeV3Turbo ? .whisperLargeV3Turbo : .whisperSmallEn
        }
    }

    func beginRecording() {
        phase = .recording
        overlayMessage = "Listening"
        recordingDuration = 0
        micInputStatus = .ok
        interleavedTyping = false
        liveTranscript = LiveTranscript()
        levelWindow.removeAll(keepingCapacity: true)
        lastAudibleAt = 0
        hasHeardAudio = false
        micProvenHealthy = false

        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickRecordingClock() }
        }
    }

    func endRecordingClock() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    func resetSessionUI() {
        endRecordingClock()
        phase = .idle
        audioLevel = 0
        recordingDuration = 0
        interleavedTyping = false
        overlayMessage = "Listening"
        liveTranscript = LiveTranscript()
        micInputStatus = .ok
    }

    func setInterleavedTyping() {
        interleavedTyping = true
        overlayMessage = "Typing detected · Hyper+D to finish"
    }

    private func tickRecordingClock() {
        recordingDuration += 0.1
        levelWindow.append(audioLevel)
        if levelWindow.count > 20 { levelWindow.removeFirst() }

        if audioLevel >= 0.05 {
            hasHeardAudio = true
            lastAudibleAt = recordingDuration
        }
        if audioLevel >= 0.20 { micProvenHealthy = true }

        let average = levelWindow.isEmpty ? 0 : levelWindow.reduce(0, +) / Float(levelWindow.count)
        if !hasHeardAudio && recordingDuration >= 3 && average < 0.05 {
            micInputStatus = .silent
        } else if hasHeardAudio && recordingDuration - lastAudibleAt >= 10 {
            micInputStatus = .silent
        } else if !micProvenHealthy && recordingDuration >= 3 {
            micInputStatus = .low
        } else {
            micInputStatus = .ok
        }
    }
}

enum LocalDictationPreferenceKey {
    static let overlayPosition = "LocalDictation.overlayPosition.v1"
    static let selectedInputDeviceUID = "LocalDictation.selectedInputDeviceUID.v1"
    static let asrSelection = "LocalDictation.asrSelection.v1"
    // Legacy keys are retained only for one-time migration.
    static let transcriptionEngine = "LocalDictation.transcriptionEngine.v1"
    static let parakeetModel = "LocalDictation.parakeetModel.v1"
    static let whisperModel = "LocalDictation.whisperModel.v1"
    static let retainDebugAudio = "LocalDictation.retainDebugAudio.v1"
    static let privateClipboardMode = "LocalDictation.privateClipboardMode.v1"
    static let experimentalModelCleanupEnabled = "LocalDictation.experimentalModelCleanupEnabled.v1"
}

enum LocalDictationKeychainAccount {
    static let openAICompatibleRefiner = "openai-compatible-refiner"
}

enum KeychainStore {
    static let service = "com.natemunk.LocalDictation"

    static var legacyServices: [String] {
        var values = [
            "com.overseed.overwhisper",
            "com.natemunk.LocalDictation.dev",
        ]
        if let bundleService = Bundle.main.bundleIdentifier,
           bundleService != service
        {
            values.insert(bundleService, at: 0)
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func save(_ value: String, account: String) throws {
        try save(value, service: service, account: account)
    }

    static func load(account: String) -> String? {
        load(service: service, account: account)
    }

    static func loadMigratingLegacyServices(account: String) -> String? {
        do {
            return try migrateValue(
                account: account,
                legacyServices: legacyServices,
                read: { load(service: $0, account: $1) },
                write: { try save($0, service: $1, account: $2) },
                delete: { delete(service: $0, account: $1) }
            )
        } catch {
            // Leave the legacy item intact and keep it usable. A later launch
            // can retry without risking key loss.
            return legacyServices.lazy.compactMap {
                load(service: $0, account: account)
            }.first
        }
    }

    static func migrateValue(
        account: String,
        currentService: String = service,
        legacyServices: [String],
        read: (_ service: String, _ account: String) -> String?,
        write: (_ value: String, _ service: String, _ account: String) throws -> Void,
        delete: (_ service: String, _ account: String) -> Void
    ) rethrows -> String? {
        if let current = read(currentService, account) { return current }
        for legacyService in legacyServices where legacyService != currentService {
            guard let value = read(legacyService, account) else { continue }
            try write(value, currentService, account)
            delete(legacyService, account)
            return value
        }
        return nil
    }

    static func delete(account: String) {
        delete(service: service, account: account)
    }

    private static func save(_ value: String, service: String, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
