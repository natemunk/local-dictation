import Foundation

/// The local ASR engines that can be installed by Local Dictation v1.
///
/// Parakeet v2 is the v1 daily-driver convention. Callers choose it explicitly
/// rather than relying on mutable process-wide selection state.
public enum ASRSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case parakeetV2
    case parakeetV3
    case whisperSmallEn
    case whisperLargeV3Turbo

    public var id: String { rawValue }

    public var isParakeet: Bool {
        switch self {
        case .parakeetV2, .parakeetV3:
            true
        case .whisperSmallEn, .whisperLargeV3Turbo:
            false
        }
    }

    public var displayName: String {
        switch self {
        case .parakeetV2:
            "Parakeet v2 — English"
        case .parakeetV3:
            "Parakeet v3 — Multilingual"
        case .whisperSmallEn:
            "WhisperKit Small English"
        case .whisperLargeV3Turbo:
            "WhisperKit Large v3 Turbo"
        }
    }

    /// Approximate download size for setup and model-selection UI.
    public var estimatedSize: String {
        switch self {
        case .parakeetV2:
            "~600 MB"
        case .parakeetV3:
            "~700 MB"
        case .whisperSmallEn:
            "~500 MB"
        case .whisperLargeV3Turbo:
            "~1.6 GB"
        }
    }

    /// The package/adapter version that owns the payload format.
    public var adapterVersion: String {
        switch self {
        case .parakeetV2, .parakeetV3:
            "fluidaudio-0.14.3"
        case .whisperSmallEn, .whisperLargeV3Turbo:
            "whisperkit-0.15.0"
        }
    }

    /// The model identifier understood by the selected adapter.
    public var modelVariant: String {
        switch self {
        case .parakeetV2:
            "parakeet-v2"
        case .parakeetV3:
            "parakeet-v3"
        case .whisperSmallEn:
            "small.en"
        case .whisperLargeV3Turbo:
            "large-v3_turbo"
        }
    }

    public var candidateID: String {
        switch self {
        case .parakeetV2:
            "parakeet-v2"
        case .parakeetV3:
            "parakeet-v3"
        case .whisperSmallEn:
            "whisperkit-small.en"
        case .whisperLargeV3Turbo:
            "whisperkit-large-v3_turbo"
        }
    }

    public init?(candidateID: String) {
        guard let selection = Self.allCases.first(where: { $0.candidateID == candidateID }) else {
            return nil
        }
        self = selection
    }

    public var sourceHost: String { "huggingface.co" }

    /// A stable, filesystem-safe component for the owned model directory.
    public var storageName: String {
        switch self {
        case .parakeetV2:
            "parakeet-v2"
        case .parakeetV3:
            "parakeet-v3"
        case .whisperSmallEn:
            "whisper-small-en"
        case .whisperLargeV3Turbo:
            "whisper-large-v3-turbo"
        }
    }
}
