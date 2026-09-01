import Foundation
import LocalDictationSpeech

@MainActor
final class ProductionCorpusRunner {
    private let runtimeProvider: any CorpusEngineRuntimeProviding
    private let audioInspector: any CorpusAudioInspecting
    private let fileManager: FileManager

    init(
        runtimeProvider: any CorpusEngineRuntimeProviding,
        audioInspector: any CorpusAudioInspecting = ProductionCorpusAudioInspector(),
        fileManager: FileManager = .default
    ) {
        self.runtimeProvider = runtimeProvider
        self.audioInspector = audioInspector
        self.fileManager = fileManager
    }

    func run(options: CorpusRunnerOptions) async throws -> CorpusRunSummary {
        guard let manifestURL = options.manifestURL,
              let outputURL = options.outputURL
        else {
            throw CorpusRunnerFailure.invalidArguments(
                "Both --manifest and --output are required"
            )
        }

        let samples = try CorpusJSONL.decodeManifest(from: manifestURL)
        let audioURLs = samples.map { resolveAudioURL($0.audioPath, manifestURL: manifestURL) }
        try validateOutputPaths(
            manifestURL: manifestURL,
            outputURL: outputURL,
            audioURLs: audioURLs,
            vocabularyURL: options.customVocabularyFileURL,
            modelRootURL: options.modelRootURL
        )
        let vocabulary = try readCustomVocabulary(from: options.customVocabularyFileURL)
        let vocabularyHash = vocabulary.isEmpty ? nil : CorpusDigest.sha256(vocabulary)
        let sanitizer = CorpusErrorSanitizer(
            modelRootURL: options.modelRootURL,
            manifestDirectoryURL: manifestURL.deletingLastPathComponent()
        )
        let runLabel = options.runLabel.map { sanitizer.sanitize($0) }
        let writer = try AtomicJSONLCheckpointWriter<CorpusRunRecord>(
            outputURL: outputURL,
            overwrite: options.overwrite,
            fileManager: fileManager
        )

        let runID = UUID().uuidString.lowercased()
        let hostOS = ProcessInfo.processInfo.operatingSystemVersionString
        let hostArchitecture = Self.hostArchitecture
        var recordCount = 0
        var errorCount = 0
        var contentLossCount = 0

        for selection in options.candidates {
            writeProgress("Loading \(selection.candidateID) from owned storage…")
            let runtimeResult: Result<CorpusEngineRuntime, Error>
            do {
                runtimeResult = .success(
                    try await runtimeProvider.runtime(
                        for: selection,
                        allowModelPreparation: options.allowModelPreparation,
                        progress: { _ in }
                    )
                )
            } catch {
                runtimeResult = .failure(error)
            }

            for (sample, audioURL) in zip(samples, audioURLs) {
                let startedAt = Date()
                let inspectionResult: Result<CorpusAudioInspection, Error>
                do {
                    inspectionResult = .success(
                        try audioInspector.inspect(
                            audioURL: audioURL,
                            declaredDuration: sample.durationSeconds
                        )
                    )
                } catch {
                    inspectionResult = .failure(error)
                }

                let record: CorpusRunRecord
                switch (runtimeResult, inspectionResult) {
                case (.success(let runtime), .success(let inspection)):
                    record = await transcribe(
                        sample: sample,
                        audioURL: audioURL,
                        inspection: inspection,
                        runtime: runtime,
                        configuration: SpeechEngineConfiguration(
                            language: options.language,
                            customVocabulary: vocabulary
                        ),
                        runID: runID,
                        runLabel: runLabel,
                        vocabularyHash: vocabularyHash,
                        hostOS: hostOS,
                        hostArchitecture: hostArchitecture,
                        startedAt: startedAt,
                        sanitizer: sanitizer
                    )

                case (.failure(let runtimeError), .success(let inspection)):
                    record = failureRecord(
                        sample: sample,
                        selection: selection,
                        inspection: inspection,
                        runtime: nil,
                        error: runtimeError,
                        runID: runID,
                        runLabel: runLabel,
                        language: options.language,
                        vocabularyHash: vocabularyHash,
                        hostOS: hostOS,
                        hostArchitecture: hostArchitecture,
                        startedAt: startedAt,
                        sanitizer: sanitizer,
                        audioURL: audioURL
                    )

                case (.success(let runtime), .failure(let audioError)):
                    record = failureRecord(
                        sample: sample,
                        selection: selection,
                        inspection: nil,
                        runtime: runtime,
                        error: audioError,
                        runID: runID,
                        runLabel: runLabel,
                        language: options.language,
                        vocabularyHash: vocabularyHash,
                        hostOS: hostOS,
                        hostArchitecture: hostArchitecture,
                        startedAt: startedAt,
                        sanitizer: sanitizer,
                        audioURL: audioURL
                    )

                case (.failure(let runtimeError), .failure(let audioError)):
                    let combined = CorpusRunnerFailure.input(
                        "\(runtimeError.localizedDescription); audio inspection also failed: \(audioError.localizedDescription)"
                    )
                    record = failureRecord(
                        sample: sample,
                        selection: selection,
                        inspection: nil,
                        runtime: nil,
                        error: combined,
                        runID: runID,
                        runLabel: runLabel,
                        language: options.language,
                        vocabularyHash: vocabularyHash,
                        hostOS: hostOS,
                        hostArchitecture: hostArchitecture,
                        startedAt: startedAt,
                        sanitizer: sanitizer,
                        audioURL: audioURL
                    )
                }

                try writer.append(record)
                recordCount += 1
                if record.status == .error { errorCount += 1 }
                if record.contentLoss { contentLossCount += 1 }
                writeProgress(
                    "Checkpointed \(record.candidate)/\(record.sampleID): \(record.status.rawValue)"
                )
            }
        }

        try writer.finalize()
        return CorpusRunSummary(
            recordCount: recordCount,
            errorCount: errorCount,
            contentLossCount: contentLossCount
        )
    }

    private func transcribe(
        sample: CorpusManifestRecord,
        audioURL: URL,
        inspection: CorpusAudioInspection,
        runtime: CorpusEngineRuntime,
        configuration: SpeechEngineConfiguration,
        runID: String,
        runLabel: String?,
        vocabularyHash: String?,
        hostOS: String,
        hostArchitecture: String,
        startedAt: Date,
        sanitizer: CorpusErrorSanitizer
    ) async -> CorpusRunRecord {
        let inferenceStart = ContinuousClock.now
        do {
            let transcript = try await runtime.engine.transcribe(
                audioURL: audioURL,
                configuration: configuration
            )
            let processingSeconds = seconds(since: inferenceStart)
            let contentLoss = transcript.text.isEmpty
            return CorpusRunRecord(
                schemaVersion: CorpusRunnerConstants.resultSchemaVersion,
                sampleID: sample.id,
                candidate: runtime.selection.candidateID,
                transcript: transcript.text,
                rawOutput: transcript.text,
                processingSeconds: processingSeconds,
                latencyMilliseconds: processingSeconds * 1_000,
                latencyScope: CorpusRunnerConstants.latencyScope,
                realTimeFactor: processingSeconds / inspection.durationSeconds,
                audioDurationSeconds: inspection.durationSeconds,
                status: .ok,
                contentLoss: contentLoss,
                latencyFailure: false,
                error: nil,
                errorType: nil,
                model: runtime.selection.modelVariant,
                modelVersion: runtime.selection.adapterVersion,
                provenance: provenance(
                    sample: sample,
                    selection: runtime.selection,
                    inspection: inspection,
                    runtime: runtime,
                    runID: runID,
                    runLabel: runLabel,
                    language: configuration.language,
                    vocabularyHash: vocabularyHash,
                    hostOS: hostOS,
                    hostArchitecture: hostArchitecture,
                    startedAt: startedAt,
                    finishedAt: Date()
                )
            )
        } catch {
            let processingSeconds = seconds(since: inferenceStart)
            return CorpusRunRecord(
                schemaVersion: CorpusRunnerConstants.resultSchemaVersion,
                sampleID: sample.id,
                candidate: runtime.selection.candidateID,
                transcript: nil,
                rawOutput: nil,
                processingSeconds: processingSeconds,
                latencyMilliseconds: processingSeconds * 1_000,
                latencyScope: CorpusRunnerConstants.latencyScope,
                realTimeFactor: processingSeconds / inspection.durationSeconds,
                audioDurationSeconds: inspection.durationSeconds,
                status: .error,
                contentLoss: false,
                latencyFailure: isLatencyFailure(error),
                error: sanitizer.sanitize(
                    error.localizedDescription,
                    audioURL: audioURL,
                    manifestAudioPath: safeManifestAudioLabel(sample.audioPath)
                ),
                errorType: String(reflecting: type(of: error)),
                model: runtime.selection.modelVariant,
                modelVersion: runtime.selection.adapterVersion,
                provenance: provenance(
                    sample: sample,
                    selection: runtime.selection,
                    inspection: inspection,
                    runtime: runtime,
                    runID: runID,
                    runLabel: runLabel,
                    language: configuration.language,
                    vocabularyHash: vocabularyHash,
                    hostOS: hostOS,
                    hostArchitecture: hostArchitecture,
                    startedAt: startedAt,
                    finishedAt: Date()
                )
            )
        }
    }

    private func failureRecord(
        sample: CorpusManifestRecord,
        selection: ASRSelection,
        inspection: CorpusAudioInspection?,
        runtime: CorpusEngineRuntime?,
        error: Error,
        runID: String,
        runLabel: String?,
        language: String,
        vocabularyHash: String?,
        hostOS: String,
        hostArchitecture: String,
        startedAt: Date,
        sanitizer: CorpusErrorSanitizer,
        audioURL: URL
    ) -> CorpusRunRecord {
        CorpusRunRecord(
            schemaVersion: CorpusRunnerConstants.resultSchemaVersion,
            sampleID: sample.id,
            candidate: selection.candidateID,
            transcript: nil,
            rawOutput: nil,
            processingSeconds: nil,
            latencyMilliseconds: nil,
            latencyScope: CorpusRunnerConstants.latencyScope,
            realTimeFactor: nil,
            audioDurationSeconds: inspection?.durationSeconds,
            status: .error,
            contentLoss: false,
            latencyFailure: isLatencyFailure(error),
            error: sanitizer.sanitize(
                error.localizedDescription,
                audioURL: audioURL,
                manifestAudioPath: safeManifestAudioLabel(sample.audioPath)
            ),
            errorType: String(reflecting: type(of: error)),
            model: selection.modelVariant,
            modelVersion: selection.adapterVersion,
            provenance: provenance(
                sample: sample,
                selection: selection,
                inspection: inspection,
                runtime: runtime,
                runID: runID,
                runLabel: runLabel,
                language: language,
                vocabularyHash: vocabularyHash,
                hostOS: hostOS,
                hostArchitecture: hostArchitecture,
                startedAt: startedAt,
                finishedAt: Date()
            )
        )
    }

    private func provenance(
        sample: CorpusManifestRecord,
        selection: ASRSelection,
        inspection: CorpusAudioInspection?,
        runtime: CorpusEngineRuntime?,
        runID: String,
        runLabel: String?,
        language: String,
        vocabularyHash: String?,
        hostOS: String,
        hostArchitecture: String,
        startedAt: Date,
        finishedAt: Date
    ) -> CorpusResultProvenance {
        CorpusResultProvenance(
            runner: CorpusRunnerConstants.runnerName,
            runnerVersion: CorpusRunnerConstants.runnerVersion,
            runID: runID,
            runLabel: runLabel,
            manifestProvenance: sample.provenance,
            audioPath: safeManifestAudioLabel(sample.audioPath),
            audioSHA256: inspection?.sha256,
            audioBytes: inspection?.byteCount,
            device: sample.device,
            noise: sample.noise,
            modelSelection: selection.rawValue,
            modelVariant: selection.modelVariant,
            adapterVersion: selection.adapterVersion,
            sourceHost: selection.sourceHost,
            installedAt: runtime.map { iso8601($0.installation.installedAt) },
            payloadRelativePath: runtime?.installation.payloadRelativePath,
            preparationPerformed: runtime?.preparationPerformed ?? false,
            engineLoadSeconds: runtime?.loadSeconds,
            language: language,
            customVocabularySHA256: vocabularyHash,
            hostOS: hostOS,
            hostArchitecture: hostArchitecture,
            startedAt: iso8601(startedAt),
            finishedAt: iso8601(finishedAt)
        )
    }

    private func validateOutputPaths(
        manifestURL: URL,
        outputURL: URL,
        audioURLs: [URL],
        vocabularyURL: URL?,
        modelRootURL: URL
    ) throws {
        let output = outputURL.standardizedFileURL
        let partial = URL(fileURLWithPath: output.path + ".partial").standardizedFileURL
        var protectedInputs = Set([manifestURL.standardizedFileURL.path])
        protectedInputs.formUnion(audioURLs.map { $0.standardizedFileURL.path })
        if let vocabularyURL {
            protectedInputs.insert(vocabularyURL.standardizedFileURL.path)
        }
        guard !protectedInputs.contains(output.path),
              !protectedInputs.contains(partial.path)
        else {
            throw CorpusRunnerFailure.unsafeOutput(
                "The output or partial checkpoint cannot overwrite a manifest, audio, or vocabulary input"
            )
        }
        let modelRoot = modelRootURL.standardizedFileURL.path
        let modelPrefix = modelRoot.hasSuffix("/") ? modelRoot : modelRoot + "/"
        guard output.path != modelRoot, !output.path.hasPrefix(modelPrefix) else {
            throw CorpusRunnerFailure.unsafeOutput(
                "Corpus results cannot be written inside the owned model root"
            )
        }
    }

    private func readCustomVocabulary(from url: URL?) throws -> String {
        guard let url else { return "" }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CorpusRunnerFailure.input(
                "Cannot read custom vocabulary at \(url.path): \(error.localizedDescription)"
            )
        }
        guard data.count <= 65_536 else {
            throw CorpusRunnerFailure.input(
                "Custom vocabulary file exceeds the 64 KiB runner limit"
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CorpusRunnerFailure.input("Custom vocabulary is not valid UTF-8")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveAudioURL(_ path: String, manifestURL: URL) -> URL {
        let url = URL(fileURLWithPath: path)
        if url.path.hasPrefix("/") {
            return url.standardizedFileURL
        }
        return manifestURL.deletingLastPathComponent()
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    private func safeManifestAudioLabel(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let url = URL(fileURLWithPath: path)
        return "manifest-audio/\(url.lastPathComponent)"
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1.0e18
    }

    private func isLatencyFailure(_ error: Error) -> Bool {
        guard let whisperError = error as? WhisperKitError else { return false }
        if case .timeout = whisperError { return true }
        return false
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func writeProgress(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
