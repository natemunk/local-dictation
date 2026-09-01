import CoreML
@preconcurrency import FluidAudio
import Foundation
@preconcurrency import WhisperKit

public enum SpeechModelNetworkPolicy: Sendable {
    /// Load only a complete Local Dictation-owned installation. This path never
    /// calls either model SDK's download API.
    case offlineOnly

    /// Permit model/tokenizer preparation inside a caller-owned staging area.
    case allowPreparation
}

public struct StagedProductionSpeechEngine: Sendable {
    public let engine: any ProductionFinalSpeechEngine
    public let payloadRelativePath: String

    public init(
        engine: any ProductionFinalSpeechEngine,
        payloadRelativePath: String
    ) {
        self.engine = engine
        self.payloadRelativePath = payloadRelativePath
    }
}

public enum ProductionSpeechEngineLoaderError: LocalizedError {
    case unsupportedSelection(ASRSelection)
    case missingModelFile(String)
    case missingOwnedTokenizer
    case invalidOwnedTokenizer(String)
    case invalidVocabulary
    case pathEscapedOwnedRoot

    public var errorDescription: String? {
        switch self {
        case .unsupportedSelection(let selection):
            return "Unsupported speech-engine selection: \(selection.rawValue)"
        case .missingModelFile(let name):
            return "Required model file is missing: \(name)"
        case .missingOwnedTokenizer:
            return "The owned WhisperKit installation has no local tokenizer; explicit preparation is required"
        case .invalidOwnedTokenizer(let name):
            return "The owned WhisperKit tokenizer file is invalid: \(name)"
        case .invalidVocabulary:
            return "The Parakeet vocabulary file is malformed"
        case .pathEscapedOwnedRoot:
            return "The downloaded model path escaped Local Dictation's owned staging directory"
        }
    }
}

/// Production bridge to the pinned FluidAudio and WhisperKit APIs. The app and
/// corpus runner both use this loader, so benchmark inference cannot drift into
/// a second set of decoding options or model-loading behavior.
@MainActor
public final class ProductionSpeechEngineLoader {
    public init() {}

    public func load(
        selection: ASRSelection,
        installation: ModelInstallation,
        networkPolicy: SpeechModelNetworkPolicy = .offlineOnly
    ) async throws -> any ProductionFinalSpeechEngine {
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
                tokenizerRoot: installation.currentDirectory,
                networkPolicy: networkPolicy
            )
        }
    }

    /// The only reusable speech-layer entry point that invokes model SDK
    /// download/preparation APIs. Callers must gate this behind an explicit user
    /// action or command-line flag.
    public func installAndLoad(
        selection: ASRSelection,
        stagingDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> StagedProductionSpeechEngine {
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
            return StagedProductionSpeechEngine(
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
                tokenizerRoot: stagingDirectory,
                networkPolicy: .allowPreparation
            )
            return StagedProductionSpeechEngine(
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
    ) async throws -> any ProductionFinalSpeechEngine {
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
        return ProductionParakeetEngine(selection: selection, asrManager: manager)
    }

    private func loadWhisperKit(
        selection: ASRSelection,
        payloadURL: URL,
        tokenizerRoot: URL,
        networkPolicy: SpeechModelNetworkPolicy
    ) async throws -> any ProductionFinalSpeechEngine {
        let tokenizerFolder: URL
        switch networkPolicy {
        case .offlineOnly:
            tokenizerFolder = try validatedLocalTokenizerFolder(within: tokenizerRoot)
        case .allowPreparation:
            tokenizerFolder = tokenizerRoot
        }

        let whisperKit = try await WhisperKit(
            model: selection.modelVariant,
            downloadBase: tokenizerRoot,
            modelFolder: payloadURL.path,
            tokenizerFolder: tokenizerFolder,
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
        return ProductionWhisperKitEngine(selection: selection, whisperKit: whisperKit)
    }

    private func loadCoreMLModel(
        named name: String,
        from directory: URL,
        configuration: MLModelConfiguration
    ) async throws -> MLModel {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProductionSpeechEngineLoaderError.missingModelFile(name)
        }
        return try await MLModel.load(contentsOf: url, configuration: configuration)
    }

    private func loadParakeetVocabulary(from directory: URL) throws -> [Int: String] {
        let url = directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProductionSpeechEngineLoaderError.missingModelFile(
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
                throw ProductionSpeechEngineLoaderError.invalidVocabulary
            }
            return Dictionary(uniqueKeysWithValues: pairs)
        }
        throw ProductionSpeechEngineLoaderError.invalidVocabulary
    }

    private func validatedLocalTokenizerFolder(within root: URL) throws -> URL {
        let fileManager = FileManager.default
        var directories = [root.standardizedFileURL]
        if let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    directories.append(url.standardizedFileURL)
                }
            }
        }

        for directory in directories.sorted(by: { $0.path < $1.path }) {
            let tokenizer = directory.appendingPathComponent("tokenizer.json")
            let configuration = directory.appendingPathComponent("tokenizer_config.json")
            guard fileManager.fileExists(atPath: tokenizer.path),
                  fileManager.fileExists(atPath: configuration.path)
            else { continue }
            try validateJSONObject(at: tokenizer)
            try validateJSONObject(at: configuration)
            return directory
        }
        throw ProductionSpeechEngineLoaderError.missingOwnedTokenizer
    }

    private func validateJSONObject(at url: URL) throws {
        do {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard object is [String: Any] else {
                throw ProductionSpeechEngineLoaderError.invalidOwnedTokenizer(
                    url.lastPathComponent
                )
            }
        } catch let error as ProductionSpeechEngineLoaderError {
            throw error
        } catch {
            throw ProductionSpeechEngineLoaderError.invalidOwnedTokenizer(
                url.lastPathComponent
            )
        }
    }

    private func parakeetVersion(for selection: ASRSelection) throws -> AsrModelVersion {
        switch selection {
        case .parakeetV2: return .v2
        case .parakeetV3: return .v3
        case .whisperSmallEn, .whisperLargeV3Turbo:
            throw ProductionSpeechEngineLoaderError.unsupportedSelection(selection)
        }
    }

    private func parakeetRepo(for selection: ASRSelection) throws -> Repo {
        switch selection {
        case .parakeetV2: return .parakeetV2
        case .parakeetV3: return .parakeetV3
        case .whisperSmallEn, .whisperLargeV3Turbo:
            throw ProductionSpeechEngineLoaderError.unsupportedSelection(selection)
        }
    }

    private func relativePath(of child: URL, within root: URL) throws -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let childPath = child.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard childPath.hasPrefix(prefix) else {
            throw ProductionSpeechEngineLoaderError.pathEscapedOwnedRoot
        }
        return String(childPath.dropFirst(prefix.count))
    }
}
