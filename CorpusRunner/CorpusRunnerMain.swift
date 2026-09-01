import Darwin
import Foundation
import LocalDictationSpeech

@main
struct CorpusRunnerMain {
    @MainActor
    static func main() async {
        do {
            let options = try CorpusRunnerOptions.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            if options.showHelp {
                FileHandle.standardOutput.write(Data((CorpusRunnerOptions.usage + "\n").utf8))
                Darwin.exit(0)
            }

            let runner = ProductionCorpusRunner(
                runtimeProvider: ProductionCorpusEngineRuntimeProvider(
                    store: OwnedModelStore(rootURL: options.modelRootURL)
                )
            )
            let summary = try await runner.run(options: options)
            let message = "Wrote \(summary.recordCount) records with \(summary.errorCount) errors and \(summary.contentLossCount) empty outputs.\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(summary.passed ? 0 : 2)
        } catch let error as CorpusRunnerFailure {
            let message = "error: \(error.localizedDescription)\n\n\(CorpusRunnerOptions.usage)\n"
            FileHandle.standardError.write(Data(message.utf8))
            switch error {
            case .invalidArguments, .invalidManifest, .unsafeOutput:
                Darwin.exit(64)
            case .input, .output, .modelUnavailable:
                Darwin.exit(74)
            }
        } catch {
            let message = "error: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(74)
        }
    }
}
