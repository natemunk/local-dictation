import Foundation

struct BenchmarkEvaluator {
    let configuration: BenchmarkConfiguration

    init(
        maximumRTF: Double = BenchmarkConstants.defaultMaximumRTF,
        maximumMedianLatencyMilliseconds: Double = BenchmarkConstants.defaultMaximumMedianLatencyMilliseconds,
        maximumP95LatencyMilliseconds: Double = BenchmarkConstants.defaultMaximumP95LatencyMilliseconds
    ) {
        configuration = BenchmarkConfiguration(
            protectedTokenWeight: BenchmarkConstants.protectedTokenWeight,
            maximumRTF: maximumRTF,
            maximumMedianLatencyMilliseconds: maximumMedianLatencyMilliseconds,
            maximumP95LatencyMilliseconds: maximumP95LatencyMilliseconds,
            weightedWERTieWindowPoints: BenchmarkConstants.weightedWERWindow * 100,
            p95Method: "nearest_rank",
            fasterMetric: "median_latency_ms"
        )
    }

    func evaluate(
        samples: [CorpusSample],
        results: [CandidateResult]
    ) throws -> BenchmarkReport {
        try validate(samples: samples, results: results)

        var byCandidate: [String: [String: CandidateResult]] = [:]
        for result in results {
            byCandidate[result.candidate, default: [:]][result.sampleID] = result
        }

        let candidates = byCandidate.keys.sorted().map { candidate in
            score(
                candidate: candidate,
                samples: samples,
                results: byCandidate[candidate] ?? [:]
            )
        }
        let selection = select(from: candidates)

        return BenchmarkReport(
            schemaVersion: BenchmarkConstants.reportSchemaVersion,
            corpusSampleCount: samples.count,
            candidateCount: candidates.count,
            configuration: configuration,
            candidates: candidates,
            selection: selection
        )
    }

    private func validate(samples: [CorpusSample], results: [CandidateResult]) throws {
        guard !samples.isEmpty else {
            throw BenchmarkFailure(message: "The corpus manifest has no records")
        }
        guard !results.isEmpty else {
            throw BenchmarkFailure(message: "The candidate results file has no records")
        }

        var sampleIDs = Set<String>()
        for sample in samples {
            let id = sample.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw BenchmarkFailure(message: "A corpus sample has an empty id")
            }
            guard id == sample.id else {
                throw BenchmarkFailure(message: "Corpus sample ids cannot have surrounding whitespace: \(sample.id)")
            }
            guard sampleIDs.insert(id).inserted else {
                throw BenchmarkFailure(message: "Duplicate corpus sample id: \(id)")
            }
            guard !sample.audioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BenchmarkFailure(message: "Corpus sample \(id) has an empty audio_path")
            }
            guard !sample.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !sample.device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !sample.noise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw BenchmarkFailure(
                    message: "Corpus sample \(id) requires non-empty category, device, and noise fields"
                )
            }
            guard sample.durationSeconds.isFinite, sample.durationSeconds > 0 else {
                throw BenchmarkFailure(message: "Corpus sample \(id) has invalid duration_seconds")
            }
            guard !WERScorer.tokenize(sample.reference).isEmpty else {
                throw BenchmarkFailure(message: "Corpus sample \(id) has an empty normalized reference")
            }
            guard ["synthetic", "fresh-opt-in"].contains(sample.provenance) else {
                throw BenchmarkFailure(
                    message: "Corpus sample \(id) provenance must be synthetic or fresh-opt-in"
                )
            }
            let missingProtected = WERScorer.protectedTokensAppearInReference(
                reference: sample.reference,
                protectedTokens: sample.protectedTokens
            )
            guard missingProtected.isEmpty else {
                throw BenchmarkFailure(
                    message: "Corpus sample \(id) has protected token(s) absent from its reference: "
                        + missingProtected.joined(separator: ", ")
                )
            }
        }

        var resultKeys = Set<String>()
        for result in results {
            let candidate = result.candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let sampleID = result.sampleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else {
                throw BenchmarkFailure(message: "A candidate result has an empty candidate id")
            }
            guard candidate == result.candidate, sampleID == result.sampleID else {
                throw BenchmarkFailure(
                    message: "Candidate and sample ids cannot have surrounding whitespace"
                )
            }
            guard sampleIDs.contains(sampleID) else {
                throw BenchmarkFailure(
                    message: "Candidate \(candidate) references unknown sample id: \(sampleID)"
                )
            }
            let key = candidate + "\u{0}" + sampleID
            guard resultKeys.insert(key).inserted else {
                throw BenchmarkFailure(
                    message: "Duplicate result for candidate \(candidate), sample \(sampleID)"
                )
            }
        }
    }

    private func score(
        candidate: String,
        samples: [CorpusSample],
        results: [String: CandidateResult]
    ) -> CandidateScore {
        let sampleScores = samples.map { sample in
            score(sample: sample, result: results[sample.id])
        }

        let standardEdits = sampleScores.reduce(
            EditCounts(substitutions: 0, deletions: 0, insertions: 0)
        ) { partial, sample in
            EditCounts(
                substitutions: partial.substitutions + sample.edits.substitutions,
                deletions: partial.deletions + sample.edits.deletions,
                insertions: partial.insertions + sample.edits.insertions
            )
        }
        let referenceWords = sampleScores.reduce(0) { $0 + $1.referenceWordCount }
        let weightedErrors = sampleScores.reduce(0) { $0 + $1.weightedErrors }
        let weightedReferenceWords = sampleScores.reduce(0) { $0 + $1.weightedReferenceWords }
        let totalDuration = sampleScores.reduce(0) { $0 + $1.durationSeconds }

        let processingTimes = sampleScores.compactMap(\.processingSeconds)
        let totalProcessing = processingTimes.count == sampleScores.count
            ? processingTimes.reduce(0, +)
            : nil
        let realTimeFactor = totalProcessing.map { $0 / totalDuration }

        let latencies = sampleScores.compactMap(\.latencyMilliseconds)
        let completeLatency = latencies.count == sampleScores.count
        let medianLatency = completeLatency ? median(latencies) : nil
        let p95Latency = completeLatency ? nearestRankPercentile(latencies, percentile: 0.95) : nil

        let crashSamples = sampleScores.filter {
            $0.issues.contains("crash") || $0.issues.contains("execution_error")
        }.map(\.sampleID)
        let contentLossSamples = sampleScores.filter {
            $0.issues.contains("content_loss") || $0.issues.contains("missing_result")
        }.map(\.sampleID)
        let processingFailureSamples = sampleScores.filter {
            $0.issues.contains("missing_processing_time")
                || $0.issues.contains("invalid_processing_time")
        }.map(\.sampleID)
        let latencyFailureSamples = sampleScores.filter {
            $0.issues.contains("latency_failure")
                || $0.issues.contains("missing_latency")
                || $0.issues.contains("invalid_latency")
        }.map(\.sampleID)

        let crashGate = GateResult(
            id: "crashes",
            passed: crashSamples.isEmpty,
            observations: [],
            failureSampleIDs: crashSamples,
            detail: crashSamples.isEmpty
                ? "No crash or execution-error result was reported."
                : "At least one sample reported a crash or execution error."
        )
        let contentLossGate = GateResult(
            id: "content_loss",
            passed: contentLossSamples.isEmpty,
            observations: [],
            failureSampleIDs: contentLossSamples,
            detail: contentLossSamples.isEmpty
                ? "Every sample has a non-empty transcript and no content-loss flag."
                : "A result was missing, empty after normalization, or explicitly flagged for content loss."
        )
        let rtfPassed = processingFailureSamples.isEmpty
            && realTimeFactor.map { $0 <= configuration.maximumRTF } == true
        let rtfGate = GateResult(
            id: "real_time_factor",
            passed: rtfPassed,
            observations: [
                GateObservation(
                    metric: "aggregate_rtf",
                    value: realTimeFactor,
                    limit: configuration.maximumRTF,
                    comparison: "less_than_or_equal"
                ),
            ],
            failureSampleIDs: processingFailureSamples,
            detail: rtfPassed
                ? "Aggregate processing time divided by aggregate audio duration is within the limit."
                : "RTF exceeds the limit or a sample lacks valid processing time."
        )
        let latencyPassed = latencyFailureSamples.isEmpty
            && medianLatency.map { $0 <= configuration.maximumMedianLatencyMilliseconds } == true
            && p95Latency.map { $0 <= configuration.maximumP95LatencyMilliseconds } == true
        let latencyGate = GateResult(
            id: "latency",
            passed: latencyPassed,
            observations: [
                GateObservation(
                    metric: "median_latency_ms",
                    value: medianLatency,
                    limit: configuration.maximumMedianLatencyMilliseconds,
                    comparison: "less_than_or_equal"
                ),
                GateObservation(
                    metric: "p95_latency_ms",
                    value: p95Latency,
                    limit: configuration.maximumP95LatencyMilliseconds,
                    comparison: "less_than_or_equal"
                ),
            ],
            failureSampleIDs: latencyFailureSamples,
            detail: latencyPassed
                ? "Median and nearest-rank p95 latency are within their limits."
                : "A latency flag/value failed or an aggregate latency exceeds its limit."
        )
        let gates = [crashGate, contentLossGate, rtfGate, latencyGate]

        return CandidateScore(
            candidate: candidate,
            passed: gates.allSatisfy(\.passed),
            sampleCount: sampleScores.count,
            standardEdits: standardEdits,
            referenceWordCount: referenceWords,
            standardWER: Double(standardEdits.total) / Double(referenceWords),
            weightedErrors: weightedErrors,
            weightedReferenceWords: weightedReferenceWords,
            domainWeightedWER: Double(weightedErrors) / Double(weightedReferenceWords),
            totalDurationSeconds: totalDuration,
            totalProcessingSeconds: totalProcessing,
            realTimeFactor: realTimeFactor,
            medianLatencyMilliseconds: medianLatency,
            p95LatencyMilliseconds: p95Latency,
            gates: gates,
            samples: sampleScores
        )
    }

    private func score(sample: CorpusSample, result: CandidateResult?) -> SampleScore {
        var issues: [String] = []
        let hypothesis: String
        let status: CandidateStatus?
        let processingSeconds: Double?
        let latencyMilliseconds: Double?

        guard let result else {
            issues = [
                "missing_result",
                "content_loss",
                "missing_processing_time",
                "missing_latency",
            ]
            let measurement = WERScorer.measure(
                reference: sample.reference,
                hypothesis: "",
                protectedTokens: sample.protectedTokens
            )
            return makeSampleScore(
                sample: sample,
                status: nil,
                measurement: measurement,
                processingSeconds: nil,
                latencyMilliseconds: nil,
                issues: issues
            )
        }

        status = result.status
        hypothesis = result.transcript ?? ""

        switch result.status {
        case .ok:
            break
        case .crash:
            issues.append("crash")
        case .error:
            issues.append("execution_error")
        }

        if result.contentLoss || WERScorer.tokenize(hypothesis).isEmpty {
            issues.append("content_loss")
        }
        if result.latencyFailure {
            issues.append("latency_failure")
        }

        if let processing = result.processingSeconds {
            if processing.isFinite, processing >= 0 {
                processingSeconds = processing
            } else {
                processingSeconds = nil
                issues.append("invalid_processing_time")
            }
        } else {
            processingSeconds = nil
            issues.append("missing_processing_time")
        }

        if let latency = result.latencyMilliseconds {
            if latency.isFinite, latency >= 0 {
                latencyMilliseconds = latency
            } else {
                latencyMilliseconds = nil
                issues.append("invalid_latency")
            }
        } else {
            latencyMilliseconds = nil
            issues.append("missing_latency")
        }

        let measurement = WERScorer.measure(
            reference: sample.reference,
            hypothesis: hypothesis,
            protectedTokens: sample.protectedTokens
        )
        return makeSampleScore(
            sample: sample,
            status: status,
            measurement: measurement,
            processingSeconds: processingSeconds,
            latencyMilliseconds: latencyMilliseconds,
            issues: Array(Set(issues)).sorted()
        )
    }

    private func makeSampleScore(
        sample: CorpusSample,
        status: CandidateStatus?,
        measurement: WERMeasurement,
        processingSeconds: Double?,
        latencyMilliseconds: Double?,
        issues: [String]
    ) -> SampleScore {
        SampleScore(
            sampleID: sample.id,
            category: sample.category,
            status: status,
            referenceWordCount: measurement.referenceTokens.count,
            hypothesisWordCount: measurement.hypothesisTokens.count,
            edits: measurement.edits,
            standardWER: measurement.standardWER,
            weightedErrors: measurement.weightedErrors,
            weightedReferenceWords: measurement.weightedReferenceWords,
            domainWeightedWER: measurement.domainWeightedWER,
            durationSeconds: sample.durationSeconds,
            processingSeconds: processingSeconds,
            realTimeFactor: processingSeconds.map { $0 / sample.durationSeconds },
            latencyMilliseconds: latencyMilliseconds,
            issues: issues
        )
    }

    private func select(from candidates: [CandidateScore]) -> SelectionResult {
        let passing = candidates.filter(\.passed)
        let passingIDs = passing.map(\.candidate).sorted()
        guard let lowestWeightedWER = passing.map(\.domainWeightedWER).min() else {
            return SelectionResult(
                status: .temporaryFallbackNoCandidatePassed,
                candidate: BenchmarkConstants.parakeetV2CandidateID,
                temporaryDefault: true,
                raycastDisposition: .keep,
                passingCandidates: [],
                withinOnePointCandidates: [],
                reason: "No candidate passed every gate; use Parakeet v2 temporarily and keep Raycast."
            )
        }

        let epsilon = 1e-12
        let withinOnePoint = passing.filter {
            $0.domainWeightedWER <= lowestWeightedWER + BenchmarkConstants.weightedWERWindow + epsilon
        }
        let fastestMedian = withinOnePoint.compactMap(\.medianLatencyMilliseconds).min()!
        let fastest = withinOnePoint.filter {
            abs(($0.medianLatencyMilliseconds ?? .infinity) - fastestMedian) <= epsilon
        }
        let bestWERAmongFastest = fastest.map(\.domainWeightedWER).min()!
        let exactMetricTies = fastest.filter {
            abs($0.domainWeightedWER - bestWERAmongFastest) <= epsilon
        }
        let selected = exactMetricTies.first {
            $0.candidate == BenchmarkConstants.parakeetV2CandidateID
        } ?? exactMetricTies.sorted { $0.candidate < $1.candidate }.first!

        let reason: String
        if exactMetricTies.count > 1,
           selected.candidate == BenchmarkConstants.parakeetV2CandidateID {
            reason = "Passing candidates tied exactly on weighted WER and median latency; Parakeet v2 wins the exact tie."
        } else if selected.domainWeightedWER > lowestWeightedWER + epsilon {
            reason = "The selected candidate is faster by median latency and within one weighted WER point of the lowest score."
        } else {
            reason = "The selected candidate has the fastest median latency within the one-point window around the lowest weighted WER."
        }

        return SelectionResult(
            status: .selectedPassingCandidate,
            candidate: selected.candidate,
            temporaryDefault: false,
            raycastDisposition: .benchmarkPassedOtherCutoverGatesRemain,
            passingCandidates: passingIDs,
            withinOnePointCandidates: withinOnePoint.map(\.candidate).sorted(),
            reason: reason
        )
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func nearestRankPercentile(_ values: [Double], percentile: Double) -> Double {
        let sorted = values.sorted()
        let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
        return sorted[rank - 1]
    }
}
