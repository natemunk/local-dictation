import Foundation

enum DictationFailureStage: String, Sendable { case capture, recognition }
enum MicrophoneDeviceCategory: String, Sendable { case builtIn = "built_in", usb, bluetooth, virtual, other, unknown }

/// Closed operational labels: never derive analytics from dynamic error text.
enum DictationFailureReason: String, CaseIterable, Encodable, Sendable {
    case modelUnavailable = "model_unavailable"
    case permissionDenied = "microphone_permission_denied"
    case microphoneAlreadyOwned = "microphone_already_owned"
    case microphoneStartFailed = "microphone_start_failed"
    case microphoneStartTimedOut = "microphone_start_timed_out"
    case captureStoppedEarly = "capture_stopped_early"
    case audioFinalizationFailed = "audio_finalization_failed"
    case audioProcessingFailed = "audio_processing_failed"
    case audioRenderFailed = "audio_render_failed"
    case oversizedAudioFrame = "oversized_audio_frame"
    case noAudioFrames = "no_audio_frames"
    case lowInputEnergy = "low_input_energy"
    case noSpeech = "no_speech"
    case asrTimedOut = "asr_timed_out"
    case asrFailed = "asr_failed"

    var stage: DictationFailureStage {
        switch self {
        case .noSpeech, .asrTimedOut, .asrFailed: .recognition
        default: .capture
        }
    }
    var isNeutral: Bool { self == .noSpeech || self == .lowInputEnergy }
    var recoveryAction: String {
        switch self {
        case .modelUnavailable: "Wait for the speech model to be ready, then try again."
        case .permissionDenied: "Enable Microphone access in System Settings."
        case .microphoneAlreadyOwned: "Finish the active recording, then try again."
        case .noSpeech: "No speech was recognized. Nothing was pasted."
        case .lowInputEnergy: "Very little sound reached the microphone. Check the input and mute state."
        case .asrTimedOut, .asrFailed: "Try again; any available recovery text opens in Preview."
        default: "Check the selected microphone and its connection, then try again."
        }
    }
    var displayName: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

enum CaptureInputEvidence: Sendable {
    case noFrames, lowEnergy, audible

    static func classify(frames: Int64, peakRMS: Float, heardAudio: Bool) -> Self {
        guard frames > 0 else { return .noFrames }
        // This distinguishes near-zero input, not voice from background noise.
        return heardAudio || peakRMS >= 0.005 ? .audible : .lowEnergy
    }
    var emptyTranscriptReason: DictationFailureReason {
        switch self {
        case .noFrames: .noAudioFrames
        case .lowEnergy: .lowInputEnergy
        case .audible: .noSpeech
        }
    }
}

enum CaptureReadinessPolicy {
    static let noticeDelay: Duration = .milliseconds(150)
    static func shouldShowStarting(current: Bool, recording: Bool, receivedFrame: Bool, typing: Bool) -> Bool {
        current && recording && !receivedFrame && !typing
    }
}
