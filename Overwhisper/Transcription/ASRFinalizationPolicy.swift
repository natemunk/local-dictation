import Foundation

enum ASRTranscriptSource: String, Equatable, Sendable {
    case authoritativeBatch
    case eouPreviewFallback
}

enum ASRDeliveryConstraint: Equatable, Sendable {
    case requestedDelivery
    case previewOnly
}

struct ASRFinalizationDecision: Equatable, Sendable {
    let transcript: FinalTranscript
    let source: ASRTranscriptSource
    let delivery: ASRDeliveryConstraint
    let commandsAllowed: Bool
}

enum ASRFinalizationPolicy {
    static func authoritative(_ transcript: FinalTranscript) -> ASRFinalizationDecision {
        ASRFinalizationDecision(
            transcript: transcript,
            source: .authoritativeBatch,
            delivery: .requestedDelivery,
            commandsAllowed: true
        )
    }

    static func recoverFromEOU(_ text: String) -> ASRFinalizationDecision? {
        let transcript = FinalTranscript(text: text, language: "en")
        guard !transcript.text.isEmpty else { return nil }
        return ASRFinalizationDecision(
            transcript: transcript,
            source: .eouPreviewFallback,
            delivery: .previewOnly,
            commandsAllowed: false
        )
    }
}
