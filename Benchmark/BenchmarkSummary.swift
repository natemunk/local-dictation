import Foundation

enum BenchmarkSummary {
    static func render(_ report: BenchmarkReport) -> String {
        var lines = [
            "Local Dictation benchmark",
            "Samples: \(report.corpusSampleCount) | Candidates: \(report.candidateCount) | Protected-token weight: \(report.configuration.protectedTokenWeight)x",
            String(
                format: "Gates: RTF <= %.3f | median latency <= %.0f ms | p95 latency <= %.0f ms",
                report.configuration.maximumRTF,
                report.configuration.maximumMedianLatencyMilliseconds,
                report.configuration.maximumP95LatencyMilliseconds
            ),
            "",
        ]

        for candidate in report.candidates {
            lines.append("\(candidate.candidate): \(candidate.passed ? "PASS" : "FAIL")")
            lines.append(
                "  WER \(percent(candidate.standardWER)) | weighted WER \(percent(candidate.domainWeightedWER))"
                    + " | RTF \(decimal(candidate.realTimeFactor, places: 3))"
                    + " | median \(milliseconds(candidate.medianLatencyMilliseconds))"
                    + " | p95 \(milliseconds(candidate.p95LatencyMilliseconds))"
            )
            let failedGates = candidate.gates.filter { !$0.passed }.map(\.id)
            lines.append(
                failedGates.isEmpty
                    ? "  Gates: all passed"
                    : "  Failed gates: " + failedGates.joined(separator: ", ")
            )
        }

        lines.append("")
        lines.append("Selection: \(report.selection.candidate)")
        lines.append("  \(report.selection.reason)")
        switch report.selection.raycastDisposition {
        case .keep:
            lines.append("  Raycast: keep; the benchmark gate did not pass.")
        case .benchmarkPassedOtherCutoverGatesRemain:
            lines.append("  Raycast: benchmark passed, but the separate cutover gates still remain.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }

    private static func decimal(_ value: Double?, places: Int) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.*f", places, value)
    }

    private static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f ms", value)
    }
}
