import os

/// Fixed performance milestones for one dictation request. Event names are the
/// entire signpost payload: never add transcript, destination, clipboard,
/// browser, path, or other request metadata here.
enum DictationPerformanceEvent: String, CaseIterable, Sendable {
    case hotkey = "hotkey"
    case overlay = "overlay"
    case captureReady = "capture-ready"
    case stop = "stop"
    case asr = "ASR"
    case cleanup = "cleanup"
    case clipboardWrite = "clipboard-write"
    case pasteEventPost = "paste-event-post"
    case completion = "completion"
}

@MainActor
enum DictationPerformanceSignposts {
    private static let log = OSLog(
        subsystem: AppLogger.subsystem,
        category: "performance"
    )
    private static var sessionSignpostIDs: [UInt64: OSSignpostID] = [:]

    /// Emits only a fixed event name and an optional opaque session generation.
    /// The generation is carried as the signpost ID rather than message data,
    /// so Instruments can pair one dictation without exposing request content.
    static func emit(
        _ event: DictationPerformanceEvent,
        correlationID: UInt64? = nil
    ) {
        let signpostID: OSSignpostID
        if let correlationID {
            if let existing = sessionSignpostIDs[correlationID] {
                signpostID = existing
            } else {
                let created = OSSignpostID(log: log)
                sessionSignpostIDs[correlationID] = created
                signpostID = created
            }
        } else {
            signpostID = .exclusive
        }
        switch event {
        case .hotkey:
            os_signpost(.event, log: log, name: "hotkey", signpostID: signpostID)
        case .overlay:
            os_signpost(.event, log: log, name: "overlay", signpostID: signpostID)
        case .captureReady:
            os_signpost(.event, log: log, name: "capture-ready", signpostID: signpostID)
        case .stop:
            os_signpost(.event, log: log, name: "stop", signpostID: signpostID)
        case .asr:
            os_signpost(.event, log: log, name: "ASR", signpostID: signpostID)
        case .cleanup:
            os_signpost(.event, log: log, name: "cleanup", signpostID: signpostID)
        case .clipboardWrite:
            os_signpost(.event, log: log, name: "clipboard-write", signpostID: signpostID)
        case .pasteEventPost:
            os_signpost(.event, log: log, name: "paste-event-post", signpostID: signpostID)
        case .completion:
            os_signpost(.event, log: log, name: "completion", signpostID: signpostID)
            if let correlationID {
                sessionSignpostIDs.removeValue(forKey: correlationID)
            }
        }
    }
}
