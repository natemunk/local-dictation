// Dependencies outside the UI/delivery acceptance scope. No microphone or inference runs.
import AppKit
import os

enum AppLogger { static let subsystem = "com.natemunk.LocalDictation.EditorAcceptance" }
enum PreviewNotice { static let copyFailureMessage = "Could not copy. Your draft is still here." }
enum DictationPerformanceEvent { case clipboardWrite, pasteEventPost }
enum DictationPerformanceSignposts {
    static func emit(_ event: DictationPerformanceEvent, correlationID: UInt64) {}
}
struct SystemAppleFoundationModelAdapter {
    enum Reason { case unsupportedOperatingSystem, appleIntelligenceNotEnabled, modelNotReady, deviceNotEligible, other }
    enum Availability { case available, unavailable(Reason) }
    func availability() -> Availability { .available }
}
@MainActor protocol RewriteInstructionRecording: AnyObject {
    func start(onPartial: @escaping (String) -> Void, onLevel: @escaping (Float) -> Void, onFailure: @escaping () -> Void) throws
    func stop() async throws -> URL
    func cancel()
}

enum HotkeyManager { static let syntheticPasteEventUserData: Int64 = 0x4C44_5041_5354_4501 }
