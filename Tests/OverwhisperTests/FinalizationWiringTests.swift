import Foundation
import Testing

/// Source-level integration guard for the AppDelegate glue. Model/session
/// behavior is tested separately; this does not claim live microphone/AX QA.
@Suite("Finalization cleanup wiring")
struct FinalizationWiringTests {
    @Test func lateASRReturnCannotBypassPreviewCancellation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Overwhisper/App/AppDelegate.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "let streamingFinalTask = Task"))
        let end = try #require(source.range(of: "private func recoverFinalizationTimeout", range: start.upperBound..<source.endIndex))
        let block = String(source[start.lowerBound..<end.lowerBound])
        #expect(block.contains("defer { streamingFinalTask.cancel() }"))
        let transcribe = try #require(block.range(of: "let raw = try await engine.transcribe(audioURL: audioURL)"))
        let cancel = try #require(block.range(of: "streamingFinalTask.cancel()", range: transcribe.upperBound..<block.endIndex))
        let interval = block[transcribe.upperBound..<cancel.lowerBound]
        #expect(!interval.contains("return"))
        #expect(!interval.contains("guard"))
        #expect(interval.contains("let inferenceCompleted = ProcessInfo.processInfo.systemUptime"))
        let record = try #require(block.range(of: "$0.metricDetails.record(.inference"))
        let guarded = block[cancel.upperBound..<record.lowerBound]
        #expect(guarded.contains("try Task.checkCancellation()"))
        #expect(guarded.contains("guard self.isCurrent(request.token) else { return }"))
        #expect(block[record.lowerBound...].hasPrefix("$0.metricDetails.record(.inference, from: inferenceStarted, to: inferenceCompleted)"))
    }
}
