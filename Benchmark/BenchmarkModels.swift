import Foundation

enum BenchmarkConstants {
    static let reportSchemaVersion = "1.0.0"
    static let protectedTokenWeight = 3
    static let defaultMaximumRTF = 0.20
    static let defaultMaximumMedianLatencyMilliseconds = 700.0
    static let defaultMaximumP95LatencyMilliseconds = 2_500.0
    static let weightedWERWindow = 0.01
    static let parakeetV2CandidateID = "parakeet-v2"
}

struct CorpusSample: Decodable, Sendable {
    let id: String
    let audioPath: String
    let category: String
    let device: String
    let noise: String
    let durationSeconds: Double
    let reference: String
    let protectedTokens: [String]
    let provenance: String

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
    }
}

enum CandidateStatus: String, Codable, Sendable {
    case ok
    case crash
    case error
}

struct CandidateResult: Decodable, Sendable {
    let sampleID: String
    let candidate: String
    let transcript: String?
    let processingSeconds: Double?
    let latencyMilliseconds: Double?
    let status: CandidateStatus
    let contentLoss: Bool
    let latencyFailure: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case sampleID = "sample_id"
        case candidate
        case transcript
        case processingSeconds = "processing_seconds"
        case latencyMilliseconds = "latency_ms"
        case status
        case contentLoss = "content_loss"
        case latencyFailure = "latency_failure"
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sampleID = try container.decode(String.self, forKey: .sampleID)
        candidate = try container.decode(String.self, forKey: .candidate)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        processingSeconds = try container.decodeIfPresent(Double.self, forKey: .processingSeconds)
        latencyMilliseconds = try container.decodeIfPresent(Double.self, forKey: .latencyMilliseconds)
        status = try container.decode(CandidateStatus.self, forKey: .status)
        contentLoss = try container.decodeIfPresent(Bool.self, forKey: .contentLoss) ?? false
        latencyFailure = try container.decodeIfPresent(Bool.self, forKey: .latencyFailure) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

struct EditCounts: Encodable, Equatable, Sendable {
    var substitutions: Int
    var deletions: Int
    var insertions: Int

    var total: Int { substitutions + deletions + insertions }
}

struct SampleScore: Encodable, Sendable {
    let sampleID: String
    let category: String
    let status: CandidateStatus?
    let referenceWordCount: Int
    let hypothesisWordCount: Int
    let edits: EditCounts
    let standardWER: Double
    let weightedErrors: Int
    let weightedReferenceWords: Int
    let domainWeightedWER: Double
    let durationSeconds: Double
    let processingSeconds: Double?
    let realTimeFactor: Double?
    let latencyMilliseconds: Double?
    let issues: [String]
}

struct GateObservation: Encodable, Sendable {
    let metric: String
    let value: Double?
    let limit: Double?
    let comparison: String?
}

struct GateResult: Encodable, Sendable {
    let id: String
    let passed: Bool
    let observations: [GateObservation]
    let failureSampleIDs: [String]
    let detail: String
}

struct CandidateScore: Encodable, Sendable {
    let candidate: String
    let passed: Bool
    let sampleCount: Int
    let standardEdits: EditCounts
    let referenceWordCount: Int
    let standardWER: Double
    let weightedErrors: Int
    let weightedReferenceWords: Int
    let domainWeightedWER: Double
    let totalDurationSeconds: Double
    let totalProcessingSeconds: Double?
    let realTimeFactor: Double?
    let medianLatencyMilliseconds: Double?
    let p95LatencyMilliseconds: Double?
    let gates: [GateResult]
    let samples: [SampleScore]
}

struct BenchmarkConfiguration: Encodable, Sendable {
    let protectedTokenWeight: Int
    let maximumRTF: Double
    let maximumMedianLatencyMilliseconds: Double
    let maximumP95LatencyMilliseconds: Double
    let weightedWERTieWindowPoints: Double
    let p95Method: String
    let fasterMetric: String
}

enum SelectionStatus: String, Encodable, Sendable {
    case selectedPassingCandidate = "selected_passing_candidate"
    case temporaryFallbackNoCandidatePassed = "temporary_fallback_no_candidate_passed"
}

enum RaycastDisposition: String, Encodable, Sendable {
    case keep
    case benchmarkPassedOtherCutoverGatesRemain = "benchmark_passed_other_cutover_gates_remain"
}

struct SelectionResult: Encodable, Sendable {
    let status: SelectionStatus
    let candidate: String
    let temporaryDefault: Bool
    let raycastDisposition: RaycastDisposition
    let passingCandidates: [String]
    let withinOnePointCandidates: [String]
    let reason: String
}

struct BenchmarkReport: Encodable, Sendable {
    let schemaVersion: String
    let corpusSampleCount: Int
    let candidateCount: Int
    let configuration: BenchmarkConfiguration
    let candidates: [CandidateScore]
    let selection: SelectionResult
}

struct BenchmarkFailure: Error, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
