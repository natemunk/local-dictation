import Foundation
import LocalDictationSpeech

enum CorpusRunnerConstants {
    static let resultSchemaVersion = "2.0.0"
    static let runnerName = "local-dictation-corpus-runner"
    static let runnerVersion = "1.0.0"
    static let latencyScope = "final_asr_file_dispatch_to_authoritative_transcript"
}

struct CorpusManifestRecord: Decodable, Equatable, Sendable {
    let id: String
    let audioPath: String
    let category: String
    let device: String
    let noise: String
    let durationSeconds: Double
    let reference: String
    let protectedTokens: [String]
    let provenance: String
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id
        case audioPath = "audio_path"
        case category
        case device
        case noise
        case durationSeconds = "duration_seconds"
        case reference
        case protectedTokens = "protected_tokens"
        case provenance
        case notes
    }
}

enum CorpusResultStatus: String, Encodable, Sendable {
    case ok
    case error
}

struct CorpusResultProvenance: Encodable, Equatable, Sendable {
    let runner: String
    let runnerVersion: String
    let runID: String
    let runLabel: String?
    let manifestProvenance: String
    let audioPath: String
    let audioSHA256: String?
    let audioBytes: UInt64?
    let device: String
    let noise: String
    let modelSelection: String
    let modelVariant: String
    let adapterVersion: String
    let sourceHost: String
    let installedAt: String?
    let payloadRelativePath: String?
    let preparationPerformed: Bool
    let engineLoadSeconds: Double?
    let language: String
    let customVocabularySHA256: String?
    let hostOS: String
    let hostArchitecture: String
    let startedAt: String
    let finishedAt: String

    enum CodingKeys: String, CodingKey {
        case runner
        case runnerVersion = "runner_version"
        case runID = "run_id"
        case runLabel = "run_label"
        case manifestProvenance = "manifest_provenance"
        case audioPath = "audio_path"
        case audioSHA256 = "audio_sha256"
        case audioBytes = "audio_bytes"
        case device
        case noise
        case modelSelection = "model_selection"
        case modelVariant = "model_variant"
        case adapterVersion = "adapter_version"
        case sourceHost = "source_host"
        case installedAt = "installed_at"
        case payloadRelativePath = "payload_relative_path"
        case preparationPerformed = "preparation_performed"
        case engineLoadSeconds = "engine_load_seconds"
        case language
        case customVocabularySHA256 = "custom_vocabulary_sha256"
        case hostOS = "host_os"
        case hostArchitecture = "host_architecture"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

struct CorpusRunRecord: Encodable, Equatable, Sendable {
    let schemaVersion: String
    let sampleID: String
    let candidate: String
    let transcript: String?
    let rawOutput: String?
    let processingSeconds: Double?
    let latencyMilliseconds: Double?
    let latencyScope: String
    let realTimeFactor: Double?
    let audioDurationSeconds: Double?
    let status: CorpusResultStatus
    let contentLoss: Bool
    let latencyFailure: Bool
    let error: String?
    let errorType: String?
    let model: String
    let modelVersion: String
    let provenance: CorpusResultProvenance

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sampleID = "sample_id"
        case candidate
        case transcript
        case rawOutput = "raw_output"
        case processingSeconds = "processing_seconds"
        case latencyMilliseconds = "latency_ms"
        case latencyScope = "latency_scope"
        case realTimeFactor = "rtf"
        case audioDurationSeconds = "audio_duration_seconds"
        case status
        case contentLoss = "content_loss"
        case latencyFailure = "latency_failure"
        case error
        case errorType = "error_type"
        case model
        case modelVersion = "model_version"
        case provenance
    }
}

struct CorpusRunSummary: Equatable, Sendable {
    let recordCount: Int
    let errorCount: Int
    let contentLossCount: Int

    var passed: Bool {
        errorCount == 0 && contentLossCount == 0
    }
}

struct CorpusAudioInspection: Equatable, Sendable {
    let durationSeconds: Double
    let byteCount: UInt64
    let sha256: String
}

struct CorpusEngineRuntime: Sendable {
    let selection: ASRSelection
    let engine: any ProductionFinalSpeechEngine
    let installation: ModelInstallation
    let preparationPerformed: Bool
    let loadSeconds: Double
}

enum CorpusRunnerFailure: Error, LocalizedError, Equatable {
    case invalidArguments(String)
    case invalidManifest(String)
    case unsafeOutput(String)
    case input(String)
    case output(String)
    case modelUnavailable(ASRSelection, String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message),
             .invalidManifest(let message),
             .unsafeOutput(let message),
             .input(let message),
             .output(let message):
            return message
        case .modelUnavailable(let selection, let message):
            return "\(selection.candidateID) is unavailable: \(message)"
        }
    }
}

enum CorpusJSONL {
    private static let allowedKeys: Set<String> = [
        "id",
        "audio_path",
        "category",
        "device",
        "noise",
        "duration_seconds",
        "reference",
        "protected_tokens",
        "provenance",
        "notes",
    ]
    private static let requiredKeys = allowedKeys.subtracting(["notes"])
    private static let allowedCategories: Set<String> = [
        "technical-vocabulary",
        "correction",
        "enumeration",
        "command",
        "short-dictation",
        "two-minute",
        "noise",
        "device-change",
    ]
    private static let wordPattern = try? NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:['’_-][\p{L}\p{N}]+)*"#
    )

    static func decodeManifest(from url: URL) throws -> [CorpusManifestRecord] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CorpusRunnerFailure.input(
                "Cannot read manifest at \(url.path): \(error.localizedDescription)"
            )
        }

        guard var text = String(data: data, encoding: .utf8) else {
            throw CorpusRunnerFailure.invalidManifest("The manifest is not valid UTF-8")
        }
        if text.first == "\u{feff}" {
            text.removeFirst()
        }

        let decoder = JSONDecoder()
        var records: [CorpusManifestRecord] = []
        for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                let data = Data(trimmed.utf8)
                let object = try JSONSerialization.jsonObject(with: data)
                guard let dictionary = object as? [String: Any] else {
                    throw CorpusRunnerFailure.invalidManifest(
                        "Manifest line \(offset + 1) must be a JSON object"
                    )
                }
                try validateKeys(dictionary.keys, line: offset + 1)
                records.append(
                    try decoder.decode(CorpusManifestRecord.self, from: data)
                )
            } catch let error as CorpusRunnerFailure {
                throw error
            } catch {
                throw CorpusRunnerFailure.invalidManifest(
                    "Invalid manifest JSONL at line \(offset + 1): \(error.localizedDescription)"
                )
            }
        }
        try validate(records)
        return records
    }

    private static func validateKeys(
        _ keys: Dictionary<String, Any>.Keys,
        line: Int
    ) throws {
        let present = Set(keys)
        let unknown = present.subtracting(allowedKeys).sorted()
        guard unknown.isEmpty else {
            throw CorpusRunnerFailure.invalidManifest(
                "Manifest line \(line) contains unknown field(s): \(unknown.joined(separator: ", "))"
            )
        }
        let missing = requiredKeys.subtracting(present).sorted()
        guard missing.isEmpty else {
            throw CorpusRunnerFailure.invalidManifest(
                "Manifest line \(line) is missing field(s): \(missing.joined(separator: ", "))"
            )
        }
    }

    private static func validate(_ records: [CorpusManifestRecord]) throws {
        guard !records.isEmpty else {
            throw CorpusRunnerFailure.invalidManifest("The corpus manifest has no records")
        }
        var ids = Set<String>()
        for record in records {
            guard record.id == record.id.trimmingCharacters(in: .whitespacesAndNewlines),
                  isValidIdentifier(record.id)
            else {
                throw CorpusRunnerFailure.invalidManifest(
                    "Corpus sample ids must match [A-Za-z0-9][A-Za-z0-9._-]*"
                )
            }
            guard ids.insert(record.id).inserted else {
                throw CorpusRunnerFailure.invalidManifest(
                    "Duplicate corpus sample id: \(record.id)"
                )
            }
            guard !record.audioPath.isEmpty,
                  record.audioPath == record.audioPath.trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                throw CorpusRunnerFailure.invalidManifest(
                    "Corpus sample \(record.id) has an empty audio_path"
                )
            }
            guard allowedCategories.contains(record.category) else {
                throw CorpusRunnerFailure.invalidManifest(
                    "Corpus sample \(record.id) has an unsupported category"
                )
            }
            guard isNonemptyTrimmed(record.device), isNonemptyTrimmed(record.noise) else {
                throw CorpusRunnerFailure.invalidManifest(
                    "Corpus sample \(record.id) requires non-empty device and noise labels"
                )
            }
            guard record.durationSeconds.isFinite, record.durationSeconds > 0 else {
                throw CorpusRunnerFailure.invalidManifest(
                    "Corpus sample \(record.id) has an invalid duration_seconds"
                )
            }
            let referenceWords = normalizedWords(record.reference)
            guard !referenceWords.isEmpty else {
                throw CorpusRunnerFailure.invalidManifest(
                    "Corpus sample \(record.id) has an empty normalized reference"
                )
            }
            guard ["synthetic", "fresh-opt-in"].contains(record.provenance) else {
                throw CorpusRunnerFailure.invalidManifest(
                    "Corpus sample \(record.id) provenance must be synthetic or fresh-opt-in"
                )
            }
            guard Set(record.protectedTokens).count == record.protectedTokens.count,
                  record.protectedTokens.allSatisfy(isNonemptyTrimmed)
            else {
                throw CorpusRunnerFailure.invalidManifest(
                    "Corpus sample \(record.id) protected_tokens must be unique non-empty phrases"
                )
            }
            let missingProtected = record.protectedTokens.filter {
                !contains(phrase: normalizedWords($0), in: referenceWords)
            }
            guard missingProtected.isEmpty else {
                throw CorpusRunnerFailure.invalidManifest(
                    "Corpus sample \(record.id) has protected token(s) absent from its reference: "
                        + missingProtected.joined(separator: ", ")
                )
            }
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, isASCIILetterOrNumber(first) else { return false }
        return bytes.allSatisfy {
            isASCIILetterOrNumber($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    private static func isASCIILetterOrNumber(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
    }

    private static func isNonemptyTrimmed(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedWords(_ text: String) -> [String] {
        guard let wordPattern else { return [] }
        let canonical = text.precomposedStringWithCanonicalMapping
        let range = NSRange(canonical.startIndex..<canonical.endIndex, in: canonical)
        return wordPattern.matches(in: canonical, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: canonical) else { return nil }
            return canonical[tokenRange]
                .replacingOccurrences(of: "’", with: "'")
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
        }
    }

    private static func contains(phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= words.count else { return false }
        for start in 0...(words.count - phrase.count) {
            if Array(words[start..<(start + phrase.count)]) == phrase {
                return true
            }
        }
        return false
    }
}
