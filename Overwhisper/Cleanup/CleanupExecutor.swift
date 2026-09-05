import Foundation

/// Keeps transcript cleanup away from the main actor so hotkey and overlay
/// responsiveness cannot be blocked by vocabulary, command, or validation
/// work. Calls are serialized because only one dictation session may own the
/// delivery pipeline at a time.
actor CleanupExecutor {
    func process(
        _ pipeline: CleanupPipeline,
        transcript: FinalTranscript,
        mode: CleanupMode
    ) async throws -> CleanupResult {
        try Task.checkCancellation()
        let result = try await pipeline.process(transcript, mode: mode)
        try Task.checkCancellation()
        return result
    }
}
