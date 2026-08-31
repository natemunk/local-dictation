import Darwin
import Foundation

private struct CLIOptions {
    var manifestPath: String?
    var resultsPath: String?
    var jsonOutputPath: String?
    var summaryOutputPath: String?
    var maximumRTF = BenchmarkConstants.defaultMaximumRTF
    var maximumMedianLatencyMilliseconds = BenchmarkConstants.defaultMaximumMedianLatencyMilliseconds
    var maximumP95LatencyMilliseconds = BenchmarkConstants.defaultMaximumP95LatencyMilliseconds
    var showHelp = false

    static let usage = """
    Usage:
      local-dictation-benchmark \\
        --manifest <corpus.jsonl> \\
        --results <candidate-results.jsonl> \\
        [--max-rtf 0.20] \\
        [--max-median-latency-ms 700] \\
        [--max-p95-latency-ms 2500] \\
        [--json-output <report.json>] \\
        [--summary-output <summary.txt>]

    Output defaults:
      Machine-readable JSON is written to stdout.
      The readable summary is written to stderr.

    Exit codes:
      0   A passing candidate was selected.
      2   No candidate passed; JSON still selects temporary parakeet-v2 and says to keep Raycast.
      64  Invalid arguments or input data.
    """

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var index = 0

        func value(after option: String) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw BenchmarkFailure(message: "Missing value after \(option)")
            }
            index = valueIndex
            return arguments[valueIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                options.showHelp = true
            case "--manifest":
                options.manifestPath = try value(after: argument)
            case "--results":
                options.resultsPath = try value(after: argument)
            case "--json-output":
                options.jsonOutputPath = try value(after: argument)
            case "--summary-output":
                options.summaryOutputPath = try value(after: argument)
            case "--max-rtf":
                options.maximumRTF = try positiveNumber(try value(after: argument), option: argument)
            case "--max-median-latency-ms":
                options.maximumMedianLatencyMilliseconds = try positiveNumber(
                    try value(after: argument),
                    option: argument
                )
            case "--max-p95-latency-ms":
                options.maximumP95LatencyMilliseconds = try positiveNumber(
                    try value(after: argument),
                    option: argument
                )
            default:
                throw BenchmarkFailure(message: "Unknown argument: \(argument)")
            }
            index += 1
        }

        return options
    }

    private static func positiveNumber(_ raw: String, option: String) throws -> Double {
        guard let value = Double(raw), value.isFinite, value > 0 else {
            throw BenchmarkFailure(message: "\(option) requires a finite number greater than zero")
        }
        return value
    }
}

private func write(_ data: Data, to path: String?, defaultHandle: FileHandle) throws {
    if let path {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw BenchmarkFailure(message: "Cannot write \(path): \(error.localizedDescription)")
        }
    } else {
        defaultHandle.write(data)
    }
}

private func validateOutputPaths(
    manifestPath: String,
    resultsPath: String,
    jsonOutputPath: String?,
    summaryOutputPath: String?
) throws {
    func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    let inputPaths = Set([manifestPath, resultsPath].map(standardized))
    let outputs = [jsonOutputPath, summaryOutputPath].compactMap { $0 }.map(standardized)
    if outputs.contains(where: inputPaths.contains) {
        throw BenchmarkFailure(message: "An output path cannot overwrite an input JSONL file")
    }
    if outputs.count == 2, outputs[0] == outputs[1] {
        throw BenchmarkFailure(message: "JSON and summary output paths must be different")
    }
}

private func run() throws -> Int32 {
    let options = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
    if options.showHelp {
        FileHandle.standardOutput.write(Data((CLIOptions.usage + "\n").utf8))
        return 0
    }

    guard let manifestPath = options.manifestPath else {
        throw BenchmarkFailure(message: "--manifest is required")
    }
    guard let resultsPath = options.resultsPath else {
        throw BenchmarkFailure(message: "--results is required")
    }
    try validateOutputPaths(
        manifestPath: manifestPath,
        resultsPath: resultsPath,
        jsonOutputPath: options.jsonOutputPath,
        summaryOutputPath: options.summaryOutputPath
    )

    let samples = try JSONL.decode(CorpusSample.self, from: manifestPath)
    let results = try JSONL.decode(CandidateResult.self, from: resultsPath)
    let report = try BenchmarkEvaluator(
        maximumRTF: options.maximumRTF,
        maximumMedianLatencyMilliseconds: options.maximumMedianLatencyMilliseconds,
        maximumP95LatencyMilliseconds: options.maximumP95LatencyMilliseconds
    ).evaluate(samples: samples, results: results)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    var json = try encoder.encode(report)
    json.append(0x0A)
    let summary = Data(BenchmarkSummary.render(report).utf8)

    try write(json, to: options.jsonOutputPath, defaultHandle: .standardOutput)
    try write(summary, to: options.summaryOutputPath, defaultHandle: .standardError)

    return report.selection.status == .selectedPassingCandidate ? 0 : 2
}

do {
    Darwin.exit(try run())
} catch {
    let message = "error: \(error.localizedDescription)\n\n\(CLIOptions.usage)\n"
    FileHandle.standardError.write(Data(message.utf8))
    Darwin.exit(64)
}
