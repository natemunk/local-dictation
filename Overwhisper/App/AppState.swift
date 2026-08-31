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

    var size: String {
        switch self {
        case .v2English: "~600 MB"
        case .v3Multilingual: "~700 MB"
        }
    }

    var cacheDirectoryName: String {
        switch self {
        case .v2English: "parakeet-tdt-0.6b-v2"
        case .v3Multilingual: "parakeet-tdt-0.6b-v3"
        }
    }

    var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)
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

    var size: String {
        switch self {
        case .smallEn: "~500 MB"
        case .largeV3Turbo: "~1.6 GB"
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
    @Published var transcriptionEngine: TranscriptionEngineType {
        didSet { preferences.set(transcriptionEngine.rawValue, forKey: LocalDictationPreferenceKey.transcriptionEngine) }
    }
    @Published var parakeetModel: ParakeetModelType {
        didSet { preferences.set(parakeetModel.rawValue, forKey: LocalDictationPreferenceKey.parakeetModel) }
    }
    @Published var whisperModel: WhisperModel {
        didSet { preferences.set(whisperModel.rawValue, forKey: LocalDictationPreferenceKey.whisperModel) }
    }
    @Published var language = "en"
    @Published var customVocabulary = ""
    @Published var raycastVocabularyImportText = ""

    @Published var isModelDownloaded = false
    @Published var modelDownloadProgress: Double = 0
    @Published var isDownloadingModel = false
    @Published var isInitializingEngine = false
    @Published var downloadedModels: Set<String> = []
    @Published var parakeetDownloadedModels: Set<String> = []
    @Published var currentlyDownloadingModel: String?

    @Published var lastTranscription = ""
    @Published var lastError: String?
    @Published var microphonePermissionGranted = false
    @Published var inputMonitoringGranted = false
    @Published var accessibilityGranted = false
    @Published var hotkeyMonitoringActive = false
    @Published var hotkeyMonitoringError: String?
    @Published var hasCompletedOnboarding = false
    @Published var retainDebugAudio: Bool
    @Published var refinerAPIKey = KeychainStore.load(
        account: LocalDictationKeychainAccount.openAICompatibleRefiner
    ) ?? ""

    let debugSessionStore = DebugSessionStore()

    private var recordingTimer: Timer?
    private var levelWindow: [Float] = []
    private var lastAudibleAt: TimeInterval = 0
    private var hasHeardAudio = false
    private var micProvenHealthy = false

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        overlayPosition = preferences.string(forKey: LocalDictationPreferenceKey.overlayPosition)
            .flatMap(OverlayPosition.init(rawValue:)) ?? .bottomCenter
        selectedInputDeviceUID = preferences.string(
            forKey: LocalDictationPreferenceKey.selectedInputDeviceUID
        ) ?? ""
        transcriptionEngine = preferences.string(forKey: LocalDictationPreferenceKey.transcriptionEngine)
            .flatMap(TranscriptionEngineType.init(rawValue:)) ?? .parakeet
        parakeetModel = preferences.string(forKey: LocalDictationPreferenceKey.parakeetModel)
            .flatMap(ParakeetModelType.init(rawValue:)) ?? .v2English
        whisperModel = preferences.string(forKey: LocalDictationPreferenceKey.whisperModel)
            .flatMap(WhisperModel.init(rawValue:)) ?? .smallEn
        retainDebugAudio = preferences.bool(forKey: LocalDictationPreferenceKey.retainDebugAudio)
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
    static let transcriptionEngine = "LocalDictation.transcriptionEngine.v1"
    static let parakeetModel = "LocalDictation.parakeetModel.v1"
    static let whisperModel = "LocalDictation.whisperModel.v1"
    static let retainDebugAudio = "LocalDictation.retainDebugAudio.v1"
}

enum LocalDictationKeychainAccount {
    static let openAICompatibleRefiner = "openai-compatible-refiner"
}

enum KeychainStore {
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.natemunk.LocalDictation"
    }

    static func save(_ value: String, account: String) throws {
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

    static func load(account: String) -> String? {
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

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
