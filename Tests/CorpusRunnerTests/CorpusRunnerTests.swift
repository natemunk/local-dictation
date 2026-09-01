import Foundation
import LocalDictationSpeech
import Testing
@testable import LocalDictationCorpusRunner

@Suite("Production corpus runner")
struct CorpusRunnerTests {
    @Test("CLI defaults to offline model loading and rejects EOU candidates")
    func offlineDefaultAndEOURejection() throws {
        let options = try CorpusRunnerOptions.parse([
            "--manifest", "/tmp/corpus.jsonl",
            "--output", "/tmp/results.jsonl",
            "--candidate", "parakeet-v2",
        ])

        #expect(options.allowModelPreparation == false)
        #expect(options.candidates == [.parakeetV2])

        #expect(throws: CorpusRunnerFailure.self) {
            _ = try CorpusRunnerOptions.parse([
                "--manifest", "/tmp/corpus.jsonl",
                "--output", "/tmp/results.jsonl",
                "--candidate", "parakeet-eou-320ms",
            ])
        }
    }

    @Test("missing models cannot prepare without the explicit flag")
    @MainActor
    func preparationRequiresExplicitFlag() async throws {
        let root = try makeTemporaryDirectory(named: "model-gate")
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = FakeCorpusSpeechLoader()
        let provider = ProductionCorpusEngineRuntimeProvider(
            store: OwnedModelStore(rootURL: root),
            loader: loader
        )

        await #expect(throws: CorpusRunnerFailure.self) {
            _ = try await provider.runtime(
                for: .parakeetV2,
                allowModelPreparation: false,
                progress: { _ in }
            )
        }
        #expect(loader.installCount == 0)

        let runtime = try await provider.runtime(
            for: .parakeetV2,
            allowModelPreparation: true,
            progress: { _ in }
        )
        #expect(loader.installCount == 1)
        #expect(runtime.preparationPerformed)
    }

    @Test("partial checkpoints and final JSONL are atomically published")
    func atomicPartialAndFinalOutput() throws {
        struct Record: Codable, Equatable {
            let id: Int
        }

        let root = try makeTemporaryDirectory(named: "atomic-output")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("results.jsonl")
        let writer = try AtomicJSONLCheckpointWriter<Record>(
            outputURL: output,
            overwrite: false
        )

        try writer.append(Record(id: 1))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: writer.partialURL.path))
        #expect(try decodeLines(Record.self, from: writer.partialURL) == [Record(id: 1)])

        try writer.append(Record(id: 2))
        #expect(
            try decodeLines(Record.self, from: writer.partialURL)
                == [Record(id: 1), Record(id: 2)]
        )

        try writer.finalize()
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: writer.partialURL.path))
        #expect(
            try decodeLines(Record.self, from: output)
                == [Record(id: 1), Record(id: 2)]
        )
    }

    @Test("fake final engine emits raw output and redacted error provenance")
    @MainActor
    func rawOutputAndRedactedErrors() async throws {
        let root = try makeTemporaryDirectory(named: "runner-output")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("corpus.jsonl")
        let output = root.appendingPathComponent("results.jsonl")
        let modelRoot = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let manifestText = """
        {"id":"good","audio_path":"audio/good.wav","category":"short-dictation","device":"fixture","noise":"quiet","duration_seconds":2.0,"reference":"raw final output","protected_tokens":[],"provenance":"synthetic"}
        {"id":"bad","audio_path":"audio/bad.wav","category":"short-dictation","device":"fixture","noise":"quiet","duration_seconds":2.0,"reference":"expected failure","protected_tokens":[],"provenance":"synthetic"}
        """
        try Data((manifestText + "\n").utf8).write(to: manifest, options: .atomic)

        let runtimeProvider = FakeCorpusRuntimeProvider(
            runtime: makeRuntime(root: modelRoot)
        )
        let runner = ProductionCorpusRunner(
            runtimeProvider: runtimeProvider,
            audioInspector: FakeCorpusAudioInspector()
        )
        var options = CorpusRunnerOptions()
        options.manifestURL = manifest
        options.outputURL = output
        options.candidates = [.parakeetV2]
        options.modelRootURL = modelRoot

        let summary = try await runner.run(options: options)
        #expect(summary.recordCount == 2)
        #expect(summary.errorCount == 1)
        #expect(runtimeProvider.allowPreparationValues == [false])

        let objects = try decodeJSONObjects(from: output)
        #expect(objects.count == 2)
        let good = try #require(objects.first { $0["sample_id"] as? String == "good" })
        #expect(good["raw_output"] as? String == "raw final output")
        #expect(good["transcript"] as? String == "raw final output")
        #expect(good["model"] as? String == "parakeet-v2")
        #expect(good["model_version"] as? String == "fluidaudio-0.14.3")
        #expect(
            good["latency_scope"] as? String
                == "final_asr_file_dispatch_to_authoritative_transcript"
        )

        let bad = try #require(objects.first { $0["sample_id"] as? String == "bad" })
        let error = try #require(bad["error"] as? String)
        #expect(!error.contains("/Users/"))
        #expect(!error.contains(FileManager.default.homeDirectoryForCurrentUser.path))
        #expect(error.contains("audio/bad.wav"))
        let provenance = try #require(bad["provenance"] as? [String: Any])
        #expect(provenance["audio_path"] as? String == "audio/bad.wav")
        #expect(!(provenance["audio_path"] as? String ?? "").hasPrefix("/"))
        #expect(!FileManager.default.fileExists(atPath: output.path + ".partial"))
    }

    @Test("manifest validation matches the checked-in corpus contract")
    func manifestContractValidation() throws {
        let root = try makeTemporaryDirectory(named: "manifest-contract")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("corpus.jsonl")

        let valid = """
        {"id":"technical-001","audio_path":"audio/technical.wav","category":"technical-vocabulary","device":"built-in-microphone","noise":"quiet","duration_seconds":2.0,"reference":"Create MYE-2077 in Linear.","protected_tokens":["MYE-2077","Linear"],"provenance":"fresh-opt-in"}
        """
        try Data((valid + "\n").utf8).write(to: manifest, options: .atomic)
        #expect(try CorpusJSONL.decodeManifest(from: manifest).count == 1)

        let invalidRecords = [
            valid.replacingOccurrences(
                of: "\"technical-vocabulary\"",
                with: "\"unsupported\""
            ),
            valid.replacingOccurrences(
                of: "\"fresh-opt-in\"",
                with: "\"legacy-recording\""
            ),
            valid.replacingOccurrences(
                of: "\"MYE-2077\",\"Linear\"",
                with: "\"MYE-9999\""
            ),
            String(valid.dropLast()) + ",\"unexpected\":true}",
        ]

        for invalid in invalidRecords {
            try Data((invalid + "\n").utf8).write(to: manifest, options: .atomic)
            #expect(throws: CorpusRunnerFailure.self) {
                _ = try CorpusJSONL.decodeManifest(from: manifest)
            }
        }
    }

    private func makeRuntime(root: URL) -> CorpusEngineRuntime {
        let current = root.appendingPathComponent("current", isDirectory: true)
        let payload = current.appendingPathComponent("payload", isDirectory: true)
        let manifest = OwnedModelManifest(
            selection: .parakeetV2,
            adapterVersion: ASRSelection.parakeetV2.adapterVersion,
            sourceHost: ASRSelection.parakeetV2.sourceHost,
            payloadRelativePath: "payload",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return CorpusEngineRuntime(
            selection: .parakeetV2,
            engine: FakeProductionFinalEngine(),
            installation: ModelInstallation(
                manifest: manifest,
                currentDirectory: current,
                payloadURL: payload
            ),
            preparationPerformed: false,
            loadSeconds: 0.25
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "local-dictation-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func decodeLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map {
            try JSONDecoder().decode(T.self, from: Data($0.utf8))
        }
    }

    private func decodeJSONObjects(from url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try #require(object as? [String: Any])
        }
    }
}

@MainActor
private final class FakeCorpusSpeechLoader: CorpusSpeechEngineLoading {
    private(set) var installCount = 0

    func load(
        selection: ASRSelection,
        installation: ModelInstallation,
        networkPolicy: SpeechModelNetworkPolicy
    ) async throws -> any ProductionFinalSpeechEngine {
        FakeProductionFinalEngine()
    }

    func installAndLoad(
        selection: ASRSelection,
        stagingDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StagedProductionSpeechEngine {
        installCount += 1
        let payload = stagingDirectory.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: payload.appendingPathComponent("model.bin"))
        return StagedProductionSpeechEngine(
            engine: FakeProductionFinalEngine(),
            payloadRelativePath: "payload"
        )
    }
}

@MainActor
private final class FakeCorpusRuntimeProvider: CorpusEngineRuntimeProviding {
    let runtimeValue: CorpusEngineRuntime
    private(set) var allowPreparationValues: [Bool] = []

    init(runtime: CorpusEngineRuntime) {
        runtimeValue = runtime
    }

    func runtime(
        for selection: ASRSelection,
        allowModelPreparation: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CorpusEngineRuntime {
        allowPreparationValues.append(allowModelPreparation)
        return runtimeValue
    }
}

private struct FakeCorpusAudioInspector: CorpusAudioInspecting {
    func inspect(audioURL: URL, declaredDuration: Double) throws -> CorpusAudioInspection {
        CorpusAudioInspection(
            durationSeconds: declaredDuration,
            byteCount: 128,
            sha256: String(repeating: "a", count: 64)
        )
    }
}

private actor FakeProductionFinalEngine: ProductionFinalSpeechEngine {
    nonisolated let selection = ASRSelection.parakeetV2

    func transcribe(
        audioURL: URL,
        configuration: SpeechEngineConfiguration
    ) async throws -> FinalTranscript {
        if audioURL.lastPathComponent == "bad.wav" {
            let sensitiveModelPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Secret Models/parakeet/model.bin")
                .path
            throw NSError(
                domain: "CorpusRunnerTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed at \(audioURL.path) while loading \(sensitiveModelPath)"
                ]
            )
        }
        return FinalTranscript(text: "raw final output", language: "en")
    }
}
