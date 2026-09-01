import Foundation
import LocalDictationSpeech

struct CorpusRunnerOptions: Equatable, Sendable {
    var manifestURL: URL?
    var outputURL: URL?
    var candidates: [ASRSelection] = []
    var modelRootURL = OwnedModelStore.defaultRootURL()
    var allowModelPreparation = false
    var overwrite = false
    var language = "en"
    var customVocabularyFileURL: URL?
    var runLabel: String?
    var showHelp = false

    static let usage = """
    Usage:
      local-dictation-corpus-runner \\
        --manifest <corpus.jsonl> \\
        --output <candidate-results.jsonl> \\
        --candidate <candidate-id> [--candidate <candidate-id> ...] \\
        [--model-root <owned-model-root>] \\
        [--language en] \\
        [--custom-vocabulary-file <text-file>] \\
        [--run-label <label>] \\
        [--allow-model-preparation] \\
        [--overwrite]

    Final-engine candidate IDs:
      parakeet-v2
      parakeet-v3
      whisperkit-small.en
      whisperkit-large-v3_turbo

    Safety:
      Existing owned models are loaded offline. Missing/corrupt models are not
      downloaded or repaired unless --allow-model-preparation is present.
      Parakeet EOU/live-preview scoring is intentionally not supported here.

    Checkpoints:
      Each completed record atomically rewrites <output>.partial. On complete,
      the valid JSONL checkpoint is atomically published to <output>.

    Exit codes:
      0   Every final-engine sample completed with non-empty raw output.
      2   Results were written, but at least one sample errored or was empty.
      64  Invalid arguments, manifest, or unsafe output paths.
      74  A fatal input/output/runtime failure prevented a complete run.
    """

    static func parse(_ arguments: [String]) throws -> CorpusRunnerOptions {
        var options = CorpusRunnerOptions()
        var index = 0

        func value(after option: String) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw CorpusRunnerFailure.invalidArguments("Missing value after \(option)")
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
                options.manifestURL = fileURL(try value(after: argument))
            case "--output":
                options.outputURL = fileURL(try value(after: argument))
            case "--candidate":
                let candidate = try value(after: argument)
                guard let selection = ASRSelection(candidateID: candidate) else {
                    let suffix = candidate.localizedCaseInsensitiveContains("eou")
                        ? " EOU/live-preview candidates must be scored by a separate runner."
                        : ""
                    throw CorpusRunnerFailure.invalidArguments(
                        "Unknown final-engine candidate: \(candidate).\(suffix)"
                    )
                }
                options.candidates.append(selection)
            case "--model-root":
                options.modelRootURL = fileURL(try value(after: argument), isDirectory: true)
            case "--language":
                let language = try value(after: argument)
                guard !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CorpusRunnerFailure.invalidArguments("--language cannot be empty")
                }
                options.language = language
            case "--custom-vocabulary-file":
                options.customVocabularyFileURL = fileURL(try value(after: argument))
            case "--run-label":
                let label = try value(after: argument)
                guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CorpusRunnerFailure.invalidArguments("--run-label cannot be empty")
                }
                options.runLabel = label
            case "--allow-model-preparation":
                options.allowModelPreparation = true
            case "--overwrite":
                options.overwrite = true
            default:
                throw CorpusRunnerFailure.invalidArguments("Unknown argument: \(argument)")
            }
            index += 1
        }

        if !options.showHelp {
            guard options.manifestURL != nil else {
                throw CorpusRunnerFailure.invalidArguments("--manifest is required")
            }
            guard options.outputURL != nil else {
                throw CorpusRunnerFailure.invalidArguments("--output is required")
            }
            guard !options.candidates.isEmpty else {
                throw CorpusRunnerFailure.invalidArguments(
                    "At least one --candidate is required"
                )
            }
            let uniqueCandidates = Set(options.candidates.map(\.candidateID))
            guard uniqueCandidates.count == options.candidates.count else {
                throw CorpusRunnerFailure.invalidArguments(
                    "Each --candidate may be specified only once"
                )
            }
        }
        return options
    }

    private static func fileURL(_ path: String, isDirectory: Bool = false) -> URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory).standardizedFileURL
    }
}
