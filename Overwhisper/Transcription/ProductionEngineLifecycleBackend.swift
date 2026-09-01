import CoreML
@preconcurrency import FluidAudio
import Foundation
@preconcurrency import WhisperKit

enum ProductionEngineLifecycleError: LocalizedError {
    case unsupportedSelection(ASRSelection)
    case missingModelFile(String)
    case invalidVocabulary
    case pathEscapedOwnedRoot

    var errorDescription: String? {
        switch self {
        case .unsupportedSelection(let selection):
            return "Unsupported speech-engine selection: \(selection.rawValue)"
        case .missingModelFile(let name):
            return "Required model file is missing: \(name)"
        case .invalidVocabulary:
            return "The Parakeet vocabulary file is malformed"
        case .pathEscapedOwnedRoot:
            return "The downloaded model path escaped Local Dictation's owned staging directory"
        }
    }
}

/// Production bridge to pinned FluidAudio and WhisperKit APIs. Every path it
/// receives is created by `OwnedModelStore`; no global or other-app cache is
/// discovered, reused, or removed.
@MainActor
final class ProductionEngineLifecycleBackend: EngineLifecycleBackend {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func load(
        selection: ASRSelection,
        installation: ModelInstallation
    ) async throws -> any TranscriptionEngine {
        try Task.checkCancellation()
        switch selection {
        case .parakeetV2, .parakeetV3:
            return try await loadParakeet(
                selection: selection,
                payloadURL: installation.payloadURL
            )
        case .whisperSmallEn, .whisperLargeV3Turbo:
            return try await loadWhisperKit(
                selection: selection,
                payloadURL: installation.payloadURL,
                tokenizerRoot: installation.currentDirectory
            )
        }
    }

    func installAndLoad(
        selection: ASRSelection,
        stagingDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StagedEngineRuntime {
        try Task.checkCancellation()
        switch selection {
        case .parakeetV2, .parakeetV3:
            let version = try parakeetVersion(for: selection)
            let repo = try parakeetRepo(for: selection)
            let payload = stagingDirectory.appendingPathComponent(
                repo.folderName,
                isDirectory: true
            )
            _ = try await AsrModels.download(
                to: payload,
                version: version,
                progressHandler: { update in
                    progress(update.fractionCompleted)
                }
            )
            try Task.checkCancellation()
            let engine = try await loadParakeet(
                selection: selection,
                payloadURL: payload
            )
            return StagedEngineRuntime(
                engine: engine,
                payloadRelativePath: try relativePath(
                    of: payload,
                    within: stagingDirectory
                )
            )

        case .whisperSmallEn, .whisperLargeV3Turbo:
            let downloadBase = stagingDirectory.appendingPathComponent(
                "whisperkit-hub",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: downloadBase,
                withIntermediateDirectories: true
            )
            let payload = try await WhisperKit.download(
                variant: selection.modelVariant,
                downloadBase: downloadBase,
                progressCallback: { update in
                    progress(update.fractionCompleted)
                }
            )
            try Task.checkCancellation()
            _ = try relativePath(of: payload, within: stagingDirectory)
            let engine = try await loadWhisperKit(
                selection: selection,
                payloadURL: payload,
                tokenizerRoot: stagingDirectory
            )
            return StagedEngineRuntime(
                engine: engine,
                payloadRelativePath: try relativePath(
                    of: payload,
                    within: stagingDirectory
                )
            )
        }
    }

    private func loadParakeet(
        selection: ASRSelection,
        payloadURL: URL
    ) async throws -> any TranscriptionEngine {
        let version = try parakeetVersion(for: selection)
        let configuration = AsrModels.defaultConfiguration()

        let preprocessorConfig = MLModelConfiguration()
        preprocessorConfig.computeUnits = .cpuOnly
        let generalConfig = MLModelConfiguration()
        generalConfig.computeUnits = configuration.computeUnits

        let preprocessor = try await loadCoreMLModel(
            named: ModelNames.ASR.preprocessorFile,
            from: payloadURL,
            configuration: preprocessorConfig
        )
        let encoder = try await loadCoreMLModel(
            named: ModelNames.ASR.encoderFile,
            from: payloadURL,
            configuration: generalConfig
        )
        let decoder = try await loadCoreMLModel(
            named: ModelNames.ASR.decoderFile,
            from: payloadURL,
            configuration: generalConfig
        )
        let jointName = version == .v3
            ? ModelNames.ASR.jointV3File
            : ModelNames.ASR.jointFile
        let joint = try await loadCoreMLModel(
            named: jointName,
            from: payloadURL,
            configuration: generalConfig
        )
        let vocabulary = try loadParakeetVocabulary(from: payloadURL)
        try Task.checkCancellation()

        let models = AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: configuration,
            vocabulary: vocabulary,
            version: version
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        try Task.checkCancellation()
        return ParakeetEngine(asrManager: manager, appState: appState)
    }

    private func loadWhisperKit(
        selection: ASRSelection,
        payloadURL: URL,
        tokenizerRoot: URL
    ) async throws -> any TranscriptionEngine {
        let whisperKit = try await WhisperKit(
            model: selection.modelVariant,
            downloadBase: tokenizerRoot,
            modelFolder: payloadURL.path,
            tokenizerFolder: tokenizerRoot,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )
        try Task.checkCancellation()
        guard whisperKit.modelState == .loaded else {
            throw WhisperKitError.notInitialized
        }
        return WhisperKitEngine(whisperKit: whisperKit, appState: appState)
    }

    private func loadCoreMLModel(
        named name: String,
        from directory: URL,
        configuration: MLModelConfiguration
    ) async throws -> MLModel {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProductionEngineLifecycleError.missingModelFile(name)
        }
        return try await MLModel.load(contentsOf: url, configuration: configuration)
    }

    private func loadParakeetVocabulary(from directory: URL) throws -> [Int: String] {
        let url = directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProductionEngineLifecycleError.missingModelFile(
                ModelNames.ASR.vocabularyFile
            )
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        if let array = object as? [String] {
            return Dictionary(uniqueKeysWithValues: array.enumerated().map { ($0, $1) })
        }
        if let dictionary = object as? [String: String] {
            let pairs = dictionary.compactMap { key, value in
                Int(key).map { ($0, value) }
            }
            guard pairs.count == dictionary.count else {
                throw ProductionEngineLifecycleError.invalidVocabulary
            }
            return Dictionary(uniqueKeysWithValues: pairs)
        }
        throw ProductionEngineLifecycleError.invalidVocabulary
    }

    private func parakeetVersion(for selection: ASRSelection) throws -> AsrModelVersion {
        switch selection {
        case .parakeetV2: return .v2
        case .parakeetV3: return .v3
        case .whisperSmallEn, .whisperLargeV3Turbo:
            throw ProductionEngineLifecycleError.unsupportedSelection(selection)
        }
    }

    private func parakeetRepo(for selection: ASRSelection) throws -> Repo {
        switch selection {
        case .parakeetV2: return .parakeetV2
        case .parakeetV3: return .parakeetV3
        case .whisperSmallEn, .whisperLargeV3Turbo:
            throw ProductionEngineLifecycleError.unsupportedSelection(selection)
        }
    }

    private func relativePath(of child: URL, within root: URL) throws -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard childPath.hasPrefix(prefix) else {
            throw ProductionEngineLifecycleError.pathEscapedOwnedRoot
        }
        return String(childPath.dropFirst(prefix.count))
    }
}
