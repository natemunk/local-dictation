import Foundation

/// The outer watchdog must leave the selected final engine time to enforce
/// its own duration-aware deadline, then leave headroom for cleanup/delivery.
enum DictationFinalizationDeadline {
    static func seconds(selection: ASRSelection, audioDuration: TimeInterval) -> TimeInterval {
        guard !selection.isParakeet else { return 120 }
        return max(120, ASRDeadlinePolicy.whisperTimeoutSeconds(audioDuration: audioDuration) + 10)
    }
}

struct DictationRecoveryText: Equatable {
    let transcript: FinalTranscript
    let source: ASRTranscriptSource

    static func select(rawText: String, liveText: String) -> DictationRecoveryText? {
        let raw = FinalTranscript(text: rawText, language: "en")
        if !raw.text.isEmpty { return .init(transcript: raw, source: .authoritativeBatch) }
        guard let fallback = ASRFinalizationPolicy.recoverFromEOU(liveText) else { return nil }
        return .init(transcript: fallback.transcript, source: .eouPreviewFallback)
    }
}
