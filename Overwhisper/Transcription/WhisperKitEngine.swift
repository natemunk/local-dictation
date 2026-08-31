import Foundation
import WhisperKit

actor WhisperKitEngine: TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private let appState: AppState
    private let modelManager: ModelManager
    private var isInitialized = false
    private var isInitializing = false
    private var currentModel: String?

    init(appState: AppState, modelManager: ModelManager) {
        self.appState = appState
        self.modelManager = modelManager
    }

    private static let maxRetries = 3
    private static let retryDelaySeconds: UInt64 = 5

    func initialize() async {
        // Prevent concurrent initialization - check and set atomically before any await
        guard !isInitializing else {
            AppLogger.transcription.debug("WhisperKit initialization already in progress, skipping")
            return
        }
        isInitializing = true

        defer { isInitializing = false }

        let modelName = await appState.whisperModel.rawValue

        // Skip if already initialized with the same model
        if isInitialized && currentModel == modelName {
            return
        }

        AppLogger.transcription.info("Initializing WhisperKit with model: \(modelName)")

        // Check if model is already downloaded locally to avoid network dependency
        let cachedModelFolder = await modelManager.findModelFolder(for: modelName)
        let modelAlreadyDownloaded = cachedModelFolder != nil

        if cachedModelFolder != nil {
            AppLogger.transcription.info("Using a cached WhisperKit model")
        }

        for attempt in 1...Self.maxRetries {
            do {
                await MainActor.run {
                    appState.isDownloadingModel = true
                }

                whisperKit = try await WhisperKit(
                    model: modelName,
                    downloadBase: modelManager.devDownloadBase,
                    modelFolder: cachedModelFolder,
                    computeOptions: ModelComputeOptions(
                        audioEncoderCompute: .cpuAndNeuralEngine,
                        textDecoderCompute: .cpuAndNeuralEngine
                    ),
                    verbose: false,
                    logLevel: .none,
                    prewarm: true,
                    load: true,
                    download: !modelAlreadyDownloaded
                )

                isInitialized = true
                currentModel = modelName

                await MainActor.run {
                    appState.isDownloadingModel = false
                    appState.isModelDownloaded = true
                    appState.downloadedModels.insert(modelName)
                }

                // Refresh the model list
                await modelManager.scanForModels()

                AppLogger.transcription.info("WhisperKit initialized successfully")
                return

            } catch {
                AppLogger.transcription.error("Failed to initialize WhisperKit (attempt \(attempt)/\(Self.maxRetries)): \(error.localizedDescription)")

                if attempt < Self.maxRetries {
                    AppLogger.transcription.info("Retrying in \(Self.retryDelaySeconds) seconds...")
                    try? await Task.sleep(nanoseconds: Self.retryDelaySeconds * 1_000_000_000)
                } else {
                    await MainActor.run {
                        appState.isDownloadingModel = false
                        appState.lastError = "Failed to initialize WhisperKit: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private static let transcriptionTimeoutSeconds: UInt64 = 30

    func transcribe(audioURL: URL) async throws -> FinalTranscript {
        // Ensure initialized
        if !isInitialized {
            await initialize()
        }

        guard let whisperKit = whisperKit else {
            throw WhisperKitError.notInitialized
        }

        AppLogger.transcription.debug("Transcribing a local temporary recording")

        // V1 is English-only. Translation and language detection remain off.
        let customVocabulary = await appState.customVocabulary

        // Encode custom vocabulary as prompt tokens to bias spelling
        var promptTokens: [Int]?
        if !customVocabulary.isEmpty, let tokenizer = whisperKit.tokenizer {
            let promptText = " " + customVocabulary.trimmingCharacters(in: .whitespaces)
            promptTokens = tokenizer.encode(text: promptText)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            AppLogger.transcription.debug("Custom vocabulary prompt tokens: \(promptTokens?.count ?? 0) tokens")
        }

        let decodingOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0.0,
            temperatureFallbackCount: 5,
            sampleLength: 224,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            clipTimestamps: [],
            promptTokens: promptTokens
        )

        // Run transcription with timeout
        let transcript = try await withThrowingTaskGroup(of: FinalTranscript.self) { group in
            group.addTask {
                let results = try await whisperKit.transcribe(
                    audioPath: audioURL.path,
                    decodeOptions: decodingOptions
                )
                return Self.finalTranscript(from: results)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: Self.transcriptionTimeoutSeconds * 1_000_000_000)
                throw WhisperKitError.timeout
            }

            // Return the first result (either transcription completes or timeout fires)
            guard let result = try await group.next() else {
                throw WhisperKitError.transcriptionFailed("No result")
            }

            // Cancel the other task
            group.cancelAll()

            return result
        }

        AppLogger.transcription.debug("Local WhisperKit transcription completed")

        return transcript
    }

    private static func finalTranscript(from results: [TranscriptionResult]) -> FinalTranscript {
        var text = ""
        var language: String?
        var boundaries: [TranscriptBoundary] = []

        for result in results {
            let normalized = FinalTranscript(text: result.text, language: result.language)
            guard !normalized.text.isEmpty else { continue }

            let fragments = result.segments.map {
                TimedTranscriptFragment(
                    text: $0.text,
                    startTime: TimeInterval($0.start),
                    endTime: TimeInterval($0.end)
                )
            }
            let component = FinalTranscript(
                text: normalized.text,
                language: normalized.language,
                boundaries: TranscriptBoundaryMapper.segmentBoundaries(
                    in: normalized.text,
                    fragments: fragments
                )
            )

            let separator = text.isEmpty ? "" : " "
            let componentOffset = text.utf8.count + separator.utf8.count
            text.append(separator)
            text.append(component.text)
            boundaries.append(contentsOf: component.boundaries.map {
                TranscriptBoundary(
                    utf8Offset: componentOffset + $0.utf8Offset,
                    source: $0.source
                )
            })
            if language == nil {
                language = component.language
            }
        }

        return FinalTranscript(text: text, language: language, boundaries: boundaries)
    }
}

enum WhisperKitError: LocalizedError {
    case notInitialized
    case modelNotFound
    case transcriptionFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "WhisperKit is not initialized"
        case .modelNotFound:
            return "Whisper model not found"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .timeout:
            return "Transcription timed out after 30 seconds"
        }
    }
}
