import Foundation
import Testing
@testable import LocalDictation

/// Opt-in paired component guard. No microphone, model, user history, or paste.
/// This measures instrumentation cost, not whole-app/ASR acceptance.
@Suite("Diagnostics performance fixture", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["LD_DIAGNOSTICS_PERF"] == "1"))
struct DiagnosticsPerformanceTests {
    @Test func pairedShortDictations() async throws {
        let pipeline = CleanupPipeline()
        let text = "Um, we should ship the update tomorrow. Check the API and MYE-123 before release."
        func batch(instrumented: Bool) async throws -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<500 {
                let result = try await pipeline.process(text, mode: .clean)
                #expect(!result.text.isEmpty)
                if instrumented {
                    var details = DictationMetricDetails()
                    for phase in DictationMetricPhase.allCases {
                        let began = ProcessInfo.processInfo.systemUptime
                        details.record(phase, from: began)
                    }
                    details.captureOutcome = .captured
                    details.insertionFailure = InsertionDiagnosticFailureKind.none
                    details.insertionTier = .exactEditableElement
                    details.buildLabel = "synthetic/performance"
                    #expect(details.databaseValues.count == DictationMetricDetails.columnNames.count)
                }
            }
            return ProcessInfo.processInfo.systemUptime - start
        }
        _ = try await batch(instrumented: true)
        var baseline: [Double] = []
        var instrumented: [Double] = []
        for round in 0..<6 {
            if round.isMultiple(of: 2) {
                baseline.append(try await batch(instrumented: false))
                instrumented.append(try await batch(instrumented: true))
            } else {
                instrumented.append(try await batch(instrumented: true))
                baseline.append(try await batch(instrumented: false))
            }
        }
        baseline.sort(); instrumented.sort()
        let before = (baseline[2] + baseline[3]) / 2
        let after = (instrumented[2] + instrumented[3]) / 2
        print("DIAGNOSTICS_PERF baseline_ms=\(before * 2) instrumented_ms=\(after * 2) ratio=\(after / before)")
        #expect(before > 0 && after > 0)
    }
}
