import AppKit
import AVFoundation
import Combine
import SwiftUI
import WhisperKit

enum AppEnvironment {
    static let isDevBuild = Bundle.main.bundleIdentifier == nil
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private let coordinator = DictationCoordinator(tapHoldThreshold: 0.350)
    private let configurationStore = ConfigurationStore()
    private let browserHostnameProvider = BrowserAutomationHostnameProvider()
    private var configuration = ConfigurationSnapshot.typedDefaults
    private var profileResolver = ProfileResolver(catalog: .nativeDefaults)
    private var activeProfile = ProfileCatalog.nativeDefaults["default"]!
    private var historyStore: HistoryStore?
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var audioRecorder: AudioRecorder!
    private var audioDeviceManager: AudioDeviceManager!
    private var overlayWindow: OverlayWindow!
    private var previewWindow: PreviewWindowController!
    private var textInserter: TextInserter!
    private var modelManager: ModelManager!
    private var transcriptionEngine: (any TranscriptionEngine)?
    private var streamingTranscriber: (any StreamingTranscriber)?
    private var streamingStartTask: Task<AsyncStream<TranscriptUpdate>?, Never>?
    private var streamingUpdatesTask: Task<Void, Never>?

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var historyWindow: HistoryWindowController?
    private var recordingMenuItem: NSMenuItem?
    private var previewMenuItem: NSMenuItem?
    private var engineMenuItem: NSMenuItem?
    private var remoteMenuItem: NSMenuItem?
    private var lastTextMenuItem: NSMenuItem?

    private var cancellables = Set<AnyCancellable>()
    private var engineTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var currentDestination: DictationDestination?
    private var historyRepasteDestination: DictationDestination?
    private var currentRawText = ""
    private var currentDeliveredText = ""
    private var currentHistoryID: UUID?
    private var currentRefinementStatus: HistoryRefinementStatus = .notRequested
    private var currentPastedRaw = false
    private var currentCleanupMode: CleanupMode = .clean
    private var deliveryCommitted = false
    private var activeSessionID: UUID?
    private var sessionStartedAt: Date?
    private var warnedAtTenMinutes = false
    private var durationCapTriggered = false

    private static let onboardingKey = "LocalDictation.hasCompletedOnboarding.v1"
    private static let configurationDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/local-dictation", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        cleanupOrphanedTemporaryAudio()
        NSApp.setActivationPolicy(.accessory)

        appState.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)
        loadConfiguration(bootstrap: true)
        setupHistoryStore()
        setupComponents()
        setupMenu()
        setupBindings()
        setupSleepWakeHandling()

        if appState.hasCompletedOnboarding {
            requestHotkeyMonitoringIfPossible()
            initializeEngine()
        } else {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionTask?.cancel()
        engineTask?.cancel()
        streamingStartTask?.cancel()
        streamingUpdatesTask?.cancel()
        if let streamingTranscriber {
            Task { await streamingTranscriber.cancel() }
        }
        hotkeyManager?.stop()
        if audioRecorder?.isRecording == true { audioRecorder.cancelRecording() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionDiagnostics()
        if appState.hasCompletedOnboarding {
            requestHotkeyMonitoringIfPossible(prompt: false)
        } else if onboardingWindow != nil,
                  appState.inputMonitoringGranted,
                  appState.accessibilityGranted {
            requestHotkeyMonitoringIfPossible(prompt: false)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard appState.hasCompletedOnboarding else {
            if onboardingWindow == nil { showOnboarding() }
            onboardingWindow?.makeKeyAndOrderFront(nil)
            return false
        }

        openSettings()
        return false
    }

    private func setupComponents() {
        audioRecorder = AudioRecorder()
        audioDeviceManager = AudioDeviceManager()
        overlayWindow = OverlayWindow(appState: appState) { [weak self] in
            self?.cancelFromUI()
        }
        textInserter = TextInserter()
        modelManager = ModelManager(appState: appState)
        if let historyStore {
            historyWindow = HistoryWindowController(
                store: historyStore,
                onCopy: { [weak self] text in self?.textInserter.copyOnly(text) },
                onRepaste: { [weak self] text in self?.repasteHistoryText(text) },
                onRetryPolish: { [weak self] entry in self?.retryPolish(entry) }
            )
        }
        previewWindow = PreviewWindowController(
            onDeliver: { [weak self] text in self?.deliverPreview(text) },
            onCopy: { [weak self] text in self?.copyPreview(text) },
            onCancel: { [weak self] in self?.cancelFromUI() }
        )
        hotkeyManager = HotkeyManager(
            coordinator: coordinator,
            profileMode: { [weak self] in self?.currentProfileMode() ?? .clean },
            effectHandler: { [weak self] effects in self?.execute(effects) }
        )

        let selected = appState.selectedInputDeviceUID
        audioRecorder.setInputDevice(selected.isEmpty ? nil : audioDeviceManager.device(forUID: selected))
    }

    private func setupBindings() {
        audioRecorder.$currentLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &appState.$audioLevel)

        appState.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.updateMenu(for: phase)
                self?.updateStatusIcon(for: phase)
            }
            .store(in: &cancellables)

        appState.$recordingDuration
            .removeDuplicates()
            .sink { [weak self] duration in self?.handleDuration(duration) }
            .store(in: &cancellables)

        appState.$selectedInputDeviceUID
            .dropFirst()
            .sink { [weak self] uid in
                guard let self else { return }
                self.audioRecorder.setInputDevice(uid.isEmpty ? nil : self.audioDeviceManager.device(forUID: uid))
                if self.appState.phase != .recording { self.audioRecorder.resetAudioEngine() }
            }
            .store(in: &cancellables)

        appState.$retainDebugAudio
            .dropFirst()
            .removeDuplicates()
            .sink { enabled in
                UserDefaults.standard.set(
                    enabled,
                    forKey: LocalDictationPreferenceKey.retainDebugAudio
                )
            }
            .store(in: &cancellables)

        appState.$refinerAPIKey
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] key in
                do {
                    if key.isEmpty {
                        KeychainStore.delete(
                            account: LocalDictationKeychainAccount.openAICompatibleRefiner
                        )
                    } else {
                        try KeychainStore.save(
                            key,
                            account: LocalDictationKeychainAccount.openAICompatibleRefiner
                        )
                    }
                } catch {
                    self?.appState.lastError = "Could not update the refiner key: \(error.localizedDescription)"
                }
            }
            .store(in: &cancellables)

        audioDeviceManager.$inputDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                guard let self, !self.appState.selectedInputDeviceUID.isEmpty else { return }
                if !devices.contains(where: { $0.uid == self.appState.selectedInputDeviceUID }) {
                    self.appState.selectedInputDeviceUID = ""
                    self.audioRecorder.setInputDevice(nil)
                    if self.appState.phase == .recording {
                        self.finishForMicrophoneRecovery()
                    }
                }
            }
            .store(in: &cancellables)

        audioDeviceManager.$defaultInputDeviceID
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self,
                      self.appState.selectedInputDeviceUID.isEmpty
                else { return }
                if self.appState.phase == .recording {
                    self.finishForMicrophoneRecovery()
                } else {
                    self.audioRecorder.resetAudioEngine()
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            appState.$transcriptionEngine,
            appState.$parakeetModel,
            appState.$whisperModel
        )
        .dropFirst()
        .sink { [weak self] _, _, _ in
            self?.initializeEngine()
            self?.updateEngineMenuItem()
        }
        .store(in: &cancellables)
    }

    private func setupSleepWakeHandling() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemWillSleep() {
        if coordinator.phase.hasActiveSession { cancelFromUI() }
    }

    @objc private func systemDidWake() {
        audioRecorder.resetAudioEngine()
        hotkeyManager.stop()
        guard appState.hasCompletedOnboarding else { return }
        requestHotkeyMonitoringIfPossible(prompt: false)
        initializeEngine()
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: 48)
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = MenuBarIcon.create()
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageLeading
            button.title = " LD"
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            button.toolTip = "Local Dictation"
            button.setAccessibilityLabel("Local Dictation")
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let title = NSMenuItem(title: "Local Dictation · \(version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let attribution = NSMenuItem(title: "Based on Overwhisper · MIT", action: nil, keyEquivalent: "")
        attribution.isEnabled = false
        menu.addItem(attribution)
        menu.addItem(.separator())

        let engine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        engine.isEnabled = false
        menu.addItem(engine)
        engineMenuItem = engine
        updateEngineMenuItem()

        let remote = NSMenuItem(title: "REMOTE text refiner active", action: nil, keyEquivalent: "")
        remote.isEnabled = false
        remote.isHidden = !appState.isRemoteRefiner
        menu.addItem(remote)
        remoteMenuItem = remote

        let recording = NSMenuItem(title: "Start Dictation", action: #selector(toggleFromMenu), keyEquivalent: "")
        recording.target = self
        recording.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Dictate")
        menu.addItem(recording)
        recordingMenuItem = recording

        let preview = NSMenuItem(title: "Finish in Preview", action: #selector(previewFromMenu), keyEquivalent: "")
        preview.target = self
        preview.isHidden = true
        menu.addItem(preview)
        previewMenuItem = preview

        let copyLast = NSMenuItem(title: "Copy Last Dictation", action: #selector(copyLast), keyEquivalent: "")
        copyLast.target = self
        copyLast.isEnabled = false
        menu.addItem(copyLast)
        lastTextMenuItem = copyLast

        menu.addItem(.separator())
        let history = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        let config = NSMenuItem(title: "Open Configuration", action: #selector(openConfiguration), keyEquivalent: "")
        config.target = self
        menu.addItem(config)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Local Dictation", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func execute(_ effects: [DictationCoordinatorEffect]) {
        for effect in effects {
            switch effect {
            case .startCapture(let sessionID):
                startCapture(sessionID: sessionID)
            case .finish(let request):
                finishCapture(request)
            case .cancel:
                cancelActiveSession()
            case .interleavedTypingChanged(let detected):
                if detected { appState.setInterleavedTyping() }
            }
        }
    }

    private func startCapture(sessionID: UUID) {
        guard sessionTask == nil, !audioRecorder.isRecording else { return }
        activeSessionID = sessionID
        warnedAtTenMinutes = false
        durationCapTriggered = false
        currentDestination = nil
        currentRawText = ""
        currentDeliveredText = ""
        currentHistoryID = nil
        currentRefinementStatus = .notRequested
        currentPastedRaw = false
        currentCleanupMode = .clean
        deliveryCommitted = false
        sessionStartedAt = Date()

        // These happen before permission checks or model work so the key-down
        // feedback path stays under the 100 ms product gate.
        appState.beginRecording()
        overlayWindow.show(position: appState.overlayPosition)

        guard transcriptionEngine != nil else {
            failSession("The local speech model is still preparing. Try Hyper+D again when setup finishes.")
            return
        }

        do {
            let samples = try audioRecorder.startRecording()
            if streamingTranscriber == nil {
                appState.overlayMessage = "Listening · live text unavailable"
            } else {
                startStreamingUpdates(samples: samples)
            }
        } catch {
            failSession("Could not start the microphone: \(error.localizedDescription)")
        }
    }

    private func startStreamingUpdates(samples: AsyncStream<AudioChunk>) {
        guard let streamingTranscriber else { return }
        streamingStartTask?.cancel()
        streamingUpdatesTask?.cancel()

        let startTask = Task<AsyncStream<TranscriptUpdate>?, Never> {
            do {
                return try await streamingTranscriber.start(samples: samples)
            } catch {
                AppLogger.transcription.error(
                    "Live transcription could not start: \(error.localizedDescription)"
                )
                await MainActor.run {
                    if self.appState.phase == .recording, !self.appState.interleavedTyping {
                        self.appState.overlayMessage = "Listening · live text unavailable"
                    }
                }
                return nil
            }
        }
        streamingStartTask = startTask
        streamingUpdatesTask = Task { [weak self] in
            guard let updates = await startTask.value else { return }
            for await update in updates {
                guard !Task.isCancelled else { return }
                self?.appState.liveTranscript = LiveTranscript(
                    finalized: update.finalized,
                    volatile: update.volatile
                )
            }
            guard !Task.isCancelled,
                  self?.appState.phase == .recording,
                  self?.appState.interleavedTyping == false
            else { return }
            self?.appState.overlayMessage = "Listening · live text unavailable"
        }
    }

    private func finishStreamingTranscript() async -> FinalTranscript? {
        guard let streamingTranscriber,
              let streamingStartTask,
              await streamingStartTask.value != nil
        else {
            self.streamingStartTask = nil
            streamingUpdatesTask?.cancel()
            streamingUpdatesTask = nil
            return nil
        }

        defer {
            self.streamingStartTask = nil
            streamingUpdatesTask = nil
        }
        do {
            let final = try await streamingTranscriber.finish()
            appState.liveTranscript = LiveTranscript(finalized: final.text, volatile: "")
            return final
        } catch {
            AppLogger.transcription.error(
                "Live transcription did not produce a final result: \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func cancelStreamingSession() {
        streamingStartTask?.cancel()
        streamingUpdatesTask?.cancel()
        streamingStartTask = nil
        streamingUpdatesTask = nil
        guard let streamingTranscriber else { return }
        Task { await streamingTranscriber.cancel() }
    }

    private func finishCapture(_ request: DictationFinishRequest) {
        guard request.sessionID == activeSessionID, audioRecorder.isRecording else { return }
        appState.endRecordingClock()
        appState.phase = .finalizing
        appState.overlayMessage = "Finalizing"
        currentDestination = DictationDestination.captureFrontmost()
        activeProfile = resolveProfile(for: currentDestination).profile
        appState.activeProfileName = profileDisplayName(activeProfile)

        let audioURL: URL
        do {
            audioURL = try audioRecorder.stopRecording()
        } catch {
            failSession("Could not finish the recording: \(error.localizedDescription)")
            return
        }

        sessionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if FileManager.default.fileExists(atPath: audioURL.path) {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                self.sessionTask = nil
            }

            let started = ContinuousClock.now
            let streamingFinalTask = Task { [weak self] in
                await self?.finishStreamingTranscript()
            }
            do {
                let resolvedProfile = await self.resolveProfileIncludingHostname(
                    for: self.currentDestination
                )
                try Task.checkCancellation()
                self.activeProfile = resolvedProfile.profile
                self.appState.activeProfileName = self.profileDisplayName(resolvedProfile.profile)
                self.appState.customVocabulary = self.asrVocabularyBias()

                guard let engine = self.transcriptionEngine else {
                    throw LocalDictationError.engineUnavailable
                }
                let raw = try await engine.transcribe(audioURL: audioURL)
                _ = await streamingFinalTask.value
                try Task.checkCancellation()
                let asrLatency = started.duration(to: .now).seconds
                self.retainDebugRecordingIfEnabled(
                    at: audioURL,
                    transcript: raw.text,
                    latency: asrLatency,
                    error: nil
                )
                await self.handleRawTranscript(
                    raw,
                    request: request,
                    asrLatency: asrLatency
                )
            } catch is CancellationError {
                streamingFinalTask.cancel()
                return
            } catch {
                guard !Task.isCancelled else { return }
                let streamingFinal = await streamingFinalTask.value
                if let streamingFinal,
                   !streamingFinal.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    let latency = started.duration(to: .now).seconds
                    self.retainDebugRecordingIfEnabled(
                        at: audioURL,
                        transcript: streamingFinal.text,
                        latency: latency,
                        error: "Batch ASR failed; delivered the local streaming transcript"
                    )
                    await self.handleRawTranscript(
                        streamingFinal,
                        request: request,
                        asrLatency: latency
                    )
                    return
                }
                self.retainDebugRecordingIfEnabled(
                    at: audioURL,
                    transcript: "",
                    latency: started.duration(to: .now).seconds,
                    error: error.localizedDescription
                )
                self.failSession("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleRawTranscript(
        _ raw: FinalTranscript,
        request: DictationFinishRequest,
        asrLatency: Double
    ) async {
        guard !Task.isCancelled else { return }
        currentRawText = raw.text
        guard !currentRawText.isEmpty else {
            failSession("No speech was detected. Nothing was pasted.")
            return
        }

        appState.lastTranscription = currentRawText
        lastTextMenuItem?.isEnabled = true

        let cleanupMode: CleanupMode = request.mode == .literal
            || activeProfile.mode == .literal
            || !activeProfile.cleanupEnabled
            ? .literal
            : .clean
        currentCleanupMode = cleanupMode
        let commandAnalysis = cleanupMode == .clean
            ? CleanupCommandProcessor().analyze(currentRawText)
            : CleanupCommandResult(
                text: currentRawText,
                recognizedCommands: [],
                unrecognizedCommandCandidates: []
            )
        guard saveRawHistory(
            mode: cleanupMode,
            asrLatency: asrLatency,
            unrecognizedCommands: commandAnalysis.unrecognizedCommandCandidates.map(\.phrase)
        ) else {
            currentDeliveredText = currentRawText
            textInserter.copyOnly(currentRawText)
            failSession(
                "Raw history could not be saved. The transcript was copied to the clipboard; nothing was pasted."
            )
            return
        }

        let refinementStarted = Date()
        if cleanupMode == .clean {
            appState.phase = .polishing
            coordinator.transition(to: .polishing)
            appState.overlayMessage = "Polishing"
        }

        do {
            let result = try await makeCleanupPipeline().process(
                raw,
                mode: cleanupMode
            )
            try Task.checkCancellation()
            currentDeliveredText = result.text
            switch result.outcome {
            case .skippedLiteralMode:
                currentRefinementStatus = .notRequested
                currentPastedRaw = false
            case .accepted:
                currentRefinementStatus = .succeeded
                currentPastedRaw = false
            case .deterministicFallback:
                currentRefinementStatus = .failed
                currentPastedRaw = true
            }
            finalizeHistoryBeforeDelivery(
                refinementLatency: Date().timeIntervalSince(refinementStarted)
            )
        } catch is CancellationError {
            return
        } catch {
            currentDeliveredText = currentRawText
            currentRefinementStatus = cleanupMode == .literal ? .notRequested : .failed
            currentPastedRaw = cleanupMode == .clean
            if cleanupMode == .clean {
                markHistoryPolishFailed(error.localizedDescription)
            } else {
                finalizeHistoryBeforeDelivery(
                    refinementLatency: Date().timeIntervalSince(refinementStarted)
                )
            }
        }

        AppLogger.transcription.info("Local ASR complete in \(String(format: "%.3f", asrLatency)) seconds")
        guard !Task.isCancelled else { return }
        if request.delivery == .preview {
            showPreview()
        } else {
            await pasteCurrentText(
                showRawLabel: currentPastedRaw || cleanupMode == .literal,
                failedPolish: currentPastedRaw
            )
        }
    }

    private func showPreview() {
        coordinator.transition(to: .previewing)
        appState.phase = .previewing
        appState.overlayMessage = "Preview"
        overlayWindow.hide()
        previewWindow.show(
            text: currentDeliveredText,
            rawText: currentRawText,
            isRemoteRefiner: appState.isRemoteRefiner
        )
    }

    private func pasteCurrentText(showRawLabel: Bool, failedPolish: Bool) async {
        guard !Task.isCancelled else { return }
        coordinator.transition(to: .pasting)
        appState.phase = .pasting
        appState.overlayMessage = "Pasting"
        overlayWindow.show(position: appState.overlayPosition)
        let outcome = await textInserter.insertText(currentDeliveredText, destination: currentDestination)

        switch outcome {
        case .pasted:
            appState.overlayMessage = showRawLabel ? "Pasted raw" : "Pasted"
            updateHistoryDelivery(
                status: failedPolish ? .pastedRaw : .delivered,
                deliveredText: currentDeliveredText
            )
            deliveryCommitted = true
        case .clipboardOnly(let reason):
            appState.overlayMessage = "Copied to clipboard"
            appState.lastError = reason
            updateHistoryDelivery(
                status: .failed,
                deliveredText: currentDeliveredText,
                error: reason
            )
            deliveryCommitted = true
        case .cancelled:
            return
        }
        appState.lastTranscription = currentDeliveredText
        try? await Task.sleep(for: .milliseconds(650))
        completeSession()
    }

    private func deliverPreview(_ text: String) {
        currentDeliveredText = text
        previewWindow.close()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.sessionTask = nil }
            await self.pasteCurrentText(
                showRawLabel: self.currentPastedRaw || self.currentCleanupMode == .literal,
                failedPolish: self.currentPastedRaw
            )
        }
    }

    private func copyPreview(_ text: String) {
        currentDeliveredText = text
        textInserter.copyOnly(text)
        updateHistoryDelivery(status: .previewed, deliveredText: text)
        deliveryCommitted = true
        previewWindow.close()
        completeSession()
    }

    private func cancelFromUI() {
        execute(coordinator.escapePressed().effects)
    }

    private func cancelActiveSession() {
        let pasteMayHaveBeenCommitted = appState.phase == .pasting
        sessionTask?.cancel()
        sessionTask = nil
        cancelStreamingSession()
        if audioRecorder.isRecording { audioRecorder.cancelRecording() }
        if !deliveryCommitted,
           !pasteMayHaveBeenCommitted,
           let historyStore,
           let currentHistoryID
        {
            _ = try? historyStore.delete(id: currentHistoryID)
        }
        previewWindow.close()
        completeSession()
    }

    private func failSession(_ message: String) {
        cancelStreamingSession()
        if audioRecorder?.isRecording == true { audioRecorder.cancelRecording() }
        coordinator.transition(to: .failed)
        appState.endRecordingClock()
        appState.phase = .failed
        appState.lastError = message
        appState.overlayMessage = "Error"
        overlayWindow.show(position: appState.overlayPosition)

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.appState.phase == .failed else { return }
            self.completeSession()
        }
    }

    private func completeSession() {
        coordinator.complete()
        activeSessionID = nil
        currentDestination = nil
        currentRawText = ""
        currentDeliveredText = ""
        currentHistoryID = nil
        currentRefinementStatus = .notRequested
        currentPastedRaw = false
        currentCleanupMode = .clean
        deliveryCommitted = false
        sessionStartedAt = nil
        previewWindow.close()
        overlayWindow.hide()
        appState.resetSessionUI()
    }

    private func handleDuration(_ duration: TimeInterval) {
        guard appState.phase == .recording else { return }
        if duration >= 600, !warnedAtTenMinutes {
            warnedAtTenMinutes = true
            appState.overlayMessage = "10 minutes · preview at 15"
        }
        if duration >= TimeInterval(configuration.app.maximumRecordingDurationSeconds),
           !durationCapTriggered
        {
            durationCapTriggered = true
            execute(coordinator.durationLimitReached(profileMode: currentProfileMode()).effects)
        }
    }

    private func finishForMicrophoneRecovery() {
        appState.overlayMessage = "Microphone changed · finishing in preview"
        execute(
            coordinator.finishFromMenu(
                mode: currentProfileMode(),
                preview: true
            ).effects
        )
    }

    private func currentProfileMode() -> DictationMode {
        let resolved = resolveCurrentProfile()
        appState.activeProfileName = profileDisplayName(resolved.profile)
        return resolved.profile.mode
    }

    private func loadConfiguration(bootstrap: Bool) {
        let result = bootstrap
            ? configurationStore.bootstrapAndReload()
            : configurationStore.reload()
        configuration = result.snapshot
        profileResolver = ProfileResolver(
            catalog: configuration.profiles,
            defaultProfileID: configuration.app.defaultProfileID,
            hostnameMatchingEnabled: configuration.app.hostnameMatchingEnabled
        )
        coordinator.updateTapHoldThreshold(
            Double(configuration.app.tapHoldThresholdMilliseconds) / 1_000
        )
        appState.retainDebugAudio = configuration.app.debugAudioRetentionEnabled
            || UserDefaults.standard.bool(forKey: LocalDictationPreferenceKey.retainDebugAudio)
        appState.isRemoteRefiner = configuredRefinerIsRemote
        remoteMenuItem?.isHidden = !appState.isRemoteRefiner
        statusItem?.button?.toolTip = appState.isRemoteRefiner
            ? "Local Dictation · REMOTE text refiner active"
            : "Local Dictation"
        if let diagnostic = result.diagnostic {
            appState.lastError = "Configuration not applied: \(diagnostic.message)"
        } else if !bootstrap {
            appState.lastError = nil
        }
    }

    private func setupHistoryStore() {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = base.appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.natemunk.LocalDictation",
                isDirectory: true
            )
            let store = try HistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
            _ = try store.pruneSuccessfulEntries(
                policy: HistoryRetentionPolicy(
                    successRetentionDays: configuration.app.historySuccessRetentionDays
                )
            )
            historyStore = store
        } catch {
            appState.lastError = "History is unavailable: \(error.localizedDescription)"
        }
    }

    private func resolveCurrentProfile() -> ResolvedProfile {
        let destination = DictationDestination.captureFrontmost()
        return resolveProfile(for: destination)
    }

    private func resolveProfile(for destination: DictationDestination?) -> ResolvedProfile {
        profileResolver.resolve(profileContext(for: destination))
    }

    private func resolveProfileIncludingHostname(
        for destination: DictationDestination?
    ) async -> ResolvedProfile {
        let context = profileContext(for: destination)
        do {
            return try await profileResolver.resolve(
                context,
                using: browserHostnameProvider
            )
        } catch {
            // Browser profiles are optional. Permission denial and adapter
            // errors always retain the generic native browser profile.
            return profileResolver.resolve(context)
        }
    }

    private func profileContext(
        for destination: DictationDestination?
    ) -> ProfileResolutionContext {
        ProfileResolutionContext(
            bundleIdentifier: destination?.bundleIdentifier,
            accessibilityRole: destination?.role,
            accessibilitySubrole: destination?.subrole
        )
    }

    private func profileDisplayName(_ profile: DictationProfile) -> String {
        "\(profile.id.capitalized) · \(profile.mode.rawValue.capitalized)"
    }

    private func selectedVocabulary() -> VocabularyPack {
        configuration.vocabulary.selection(including: activeProfile.vocabularyPackIDs)
    }

    private func asrVocabularyBias() -> String {
        let vocabulary = selectedVocabulary()
        return Array(
            Set(
                vocabulary.literalPhrases
                    + vocabulary.protectedTerms
                    + Array(vocabulary.replacements.values)
            )
        )
        .sorted()
        .joined(separator: ", ")
    }

    private func makeCleanupPipeline() -> CleanupPipeline {
        let vocabulary = selectedVocabulary()
        var replacements: [CleanupVocabularyReplacement] = vocabulary.replacements.map {
            CleanupVocabularyReplacement(
                spokenForm: $0.key,
                writtenForm: $0.value,
                isProtected: true
            )
        }
        replacements.append(contentsOf: vocabulary.literalPhrases.map {
            CleanupVocabularyReplacement(spokenForm: $0, writtenForm: $0, isProtected: true)
        })
        replacements.append(contentsOf: vocabulary.protectedTerms.map {
            CleanupVocabularyReplacement(spokenForm: $0, writtenForm: $0, isProtected: true)
        })

        let configuredPatterns = vocabulary.patterns.map { pattern in
            CleanupProtectedPattern(
                name: pattern.name,
                expression: #"\b"#
                    + NSRegularExpression.escapedPattern(for: pattern.prefix)
                    + #"\d+\b"#,
                isCaseInsensitive: true
            )
        }
        return CleanupPipeline(
            vocabularyReplacements: replacements,
            protectedPatterns: CleanupProtectedPattern.standard + configuredPatterns,
            refiner: configuredTextRefiner()
        )
    }

    private func configuredTextRefiner() -> any TextRefiner {
        let app = configuration.app
        let deadline = Duration.milliseconds(
            Int64(max(1, (app.refinementDeadlineSeconds * 1_000).rounded()))
        )

        let base: any TextRefiner
        switch app.refinerMode {
        case .deterministic:
            base = DeterministicRefiner()
        case .openAICompatible:
            base = openAICompatibleRefiner(deadline: deadline) ?? DeterministicRefiner()
        case .auto:
            if app.refinerEndpoint != nil {
                base = openAICompatibleRefiner(deadline: deadline) ?? DeterministicRefiner()
            } else {
                let adapter = SystemAppleFoundationModelAdapter()
                if adapter.availability() == .available {
                    base = AppleFoundationRefiner(adapter: adapter, deadline: deadline)
                } else {
                    base = DeterministicRefiner()
                }
            }
        }

        switch activeProfile.formattingStyle {
        case .structured:
            return base
        case .chat, .prose, .plain, .terminal:
            return ProfileFormattingRefiner(
                base: base,
                allowInferredBullets: false,
                preserveParagraphBreakCount: true
            )
        }
    }

    private func openAICompatibleRefiner(deadline: Duration) -> OpenAICompatibleRefiner? {
        guard let endpoint = configuration.app.refinerEndpoint,
              let model = configuration.app.refinerModel
        else { return nil }
        let key = appState.refinerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenAICompatibleRefiner(
            configuration: OpenAICompatibleRefinerConfiguration(
                endpoint: endpoint,
                model: model,
                apiKey: key.isEmpty ? nil : key,
                allowRemote: configuration.app.allowRemote,
                deadline: deadline
            )
        )
    }

    private var configuredRefinerIsRemote: Bool {
        guard configuration.app.refinerMode != .deterministic,
              let host = configuration.app.refinerEndpoint?.host?.lowercased()
        else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
            return false
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4,
           octets.allSatisfy({ UInt8($0) != nil }),
           octets.first == "127"
        {
            return false
        }
        return true
    }

    private func retainDebugRecordingIfEnabled(
        at audioURL: URL,
        transcript: String,
        latency: TimeInterval,
        error: String?
    ) {
        guard appState.retainDebugAudio,
              FileManager.default.fileExists(atPath: audioURL.path)
        else { return }

        let engine: String
        let model: String
        switch appState.transcriptionEngine {
        case .parakeet:
            engine = "FluidAudio Parakeet"
            model = appState.parakeetModel.rawValue
        case .whisperKit:
            engine = "WhisperKit"
            model = appState.whisperModel.rawValue
        }
        _ = appState.debugSessionStore.record(
            engine: engine,
            model: model,
            sourceAudioURL: audioURL,
            recordingDuration: sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0,
            transcribedText: transcript,
            latencySeconds: latency,
            language: "en",
            errorMessage: error
        )
    }

    private func saveRawHistory(
        mode: CleanupMode,
        asrLatency: TimeInterval,
        unrecognizedCommands: [String]
    ) -> Bool {
        guard let historyStore else {
            appState.lastError = "History is unavailable"
            return false
        }
        let id = activeSessionID ?? UUID()
        do {
            _ = try historyStore.saveRaw(
                HistoryRawCapture(
                    id: id,
                    rawText: currentRawText,
                    destination: HistoryDestination(
                        bundleIdentifier: currentDestination?.bundleIdentifier,
                        displayName: currentDestination?.applicationName
                    ),
                    mode: mode == .literal ? .literal : .clean,
                    asrLatency: asrLatency,
                    unrecognizedCommandCandidates: unrecognizedCommands
                )
            )
            currentHistoryID = id
            return true
        } catch {
            appState.lastError = "Could not save raw history: \(error.localizedDescription)"
            return false
        }
    }

    private func finalizeHistoryBeforeDelivery(refinementLatency: TimeInterval) {
        guard let historyStore, let id = currentHistoryID else { return }
        do {
            _ = try historyStore.finalize(
                id: id,
                with: HistoryFinalization(
                    polishedText: currentDeliveredText,
                    refinementStatus: currentRefinementStatus,
                    deliveryStatus: .pending,
                    refinementLatency: refinementLatency,
                    totalLatency: sessionStartedAt.map { Date().timeIntervalSince($0) }
                )
            )
        } catch {
            appState.lastError = "Could not update history: \(error.localizedDescription)"
        }
    }

    private func markHistoryPolishFailed(_ error: String) {
        guard let historyStore, let id = currentHistoryID else { return }
        do {
            _ = try historyStore.markPolishFailed(
                id: id,
                error: error,
                totalLatency: sessionStartedAt.map { Date().timeIntervalSince($0) }
            )
        } catch {
            appState.lastError = "Could not mark failed polish: \(error.localizedDescription)"
        }
    }

    private func updateHistoryDelivery(
        status: HistoryDeliveryStatus,
        deliveredText: String,
        error: String? = nil
    ) {
        guard let historyStore, let id = currentHistoryID else { return }
        do {
            _ = try historyStore.updateDelivery(
                id: id,
                with: HistoryDeliveryUpdate(
                    status: status,
                    deliveredText: deliveredText,
                    totalLatency: sessionStartedAt.map { Date().timeIntervalSince($0) },
                    error: error
                )
            )
        } catch {
            appState.lastError = "Could not finalize history: \(error.localizedDescription)"
        }
    }

    private func repasteHistoryText(_ text: String) {
        let destination = historyRepasteDestination
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.textInserter.insertText(text, destination: destination)
            if case .clipboardOnly(let reason) = outcome {
                self.appState.lastError = reason
            }
        }
    }

    private func retryPolish(_ entry: HistoryEntry) {
        guard entry.refinementStatus == .failed, let historyStore else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let retry = try historyStore.beginPolishRetry(id: entry.id)
                let started = Date()
                let result = try await self.makeCleanupPipeline().process(retry.rawText, mode: .clean)
                let refinementStatus: HistoryRefinementStatus
                switch result.outcome {
                case .accepted:
                    refinementStatus = .succeeded
                case .deterministicFallback, .skippedLiteralMode:
                    refinementStatus = .failed
                }
                _ = try historyStore.finalize(
                    id: entry.id,
                    with: HistoryFinalization(
                        polishedText: result.text,
                        refinementStatus: refinementStatus,
                        deliveryStatus: entry.deliveryStatus,
                        refinementLatency: Date().timeIntervalSince(started),
                        totalLatency: entry.totalLatency,
                        error: refinementStatus == .failed ? "Retry used deterministic fallback" : nil
                    )
                )
                self.historyWindow?.refresh()
            } catch {
                _ = try? historyStore.markPolishFailed(id: entry.id, error: error.localizedDescription)
                self.appState.lastError = "Polish retry failed: \(error.localizedDescription)"
                self.historyWindow?.refresh()
            }
        }
    }

    private func initializeEngine(onCompletion: ((Bool) -> Void)? = nil) {
        engineTask?.cancel()
        cancelStreamingSession()
        streamingTranscriber = nil
        transcriptionEngine = nil
        appState.engineReady = false
        appState.isInitializingEngine = true
        engineTask = Task { [weak self] in
            guard let self else { return }
            switch self.appState.transcriptionEngine {
            case .parakeet:
                let engine = ParakeetEngine(appState: self.appState)
                do {
                    try await engine.initialize()
                    self.transcriptionEngine = engine
                    self.appState.lastError = nil
                    let streaming = FluidAudioParakeetStreamingTranscriber()
                    do {
                        try await streaming.prepare()
                        self.streamingTranscriber = streaming
                    } catch {
                        AppLogger.transcription.error(
                            "Parakeet live preview is unavailable: \(error.localizedDescription)"
                        )
                    }
                } catch {
                    self.appState.lastError = error.localizedDescription
                }
            case .whisperKit:
                let engine = WhisperKitEngine(appState: self.appState, modelManager: self.modelManager)
                await engine.initialize()
                self.transcriptionEngine = engine
                let modelName = self.appState.whisperModel.rawValue
                let cachedModelFolder = self.modelManager.findModelFolder(for: modelName)
                let streaming = WhisperKitStreamingTranscriber(
                    model: modelName,
                    downloadBase: self.modelManager.devDownloadBase,
                    modelFolder: cachedModelFolder,
                    download: cachedModelFolder == nil,
                    decodingOptions: DecodingOptions(
                        verbose: false,
                        task: .transcribe,
                        language: "en",
                        temperature: 0,
                        usePrefillPrompt: true,
                        usePrefillCache: true,
                        skipSpecialTokens: true,
                        withoutTimestamps: false
                    )
                )
                do {
                    try await streaming.prepare()
                    self.streamingTranscriber = streaming
                } catch {
                    AppLogger.transcription.error(
                        "WhisperKit live preview is unavailable: \(error.localizedDescription)"
                    )
                }
            }
            self.appState.isInitializingEngine = false
            self.appState.engineReady = self.transcriptionEngine != nil
            self.updateEngineMenuItem()
            onCompletion?(self.appState.engineReady)
        }
    }

    private func requestHotkeyMonitoringIfPossible(prompt: Bool = true) {
        requestHotkeyMonitoringIfPossible(prompt: prompt, restart: false)
    }

    private func requestHotkeyMonitoringIfPossible(prompt: Bool, restart: Bool) {
        if restart {
            hotkeyManager.stop()
        }
        do {
            try hotkeyManager.start(promptForPermission: prompt)
            appState.hotkeyMonitoringError = nil
            AppLogger.hotkey.info("Hyper+D monitoring is ready")
        } catch {
            appState.lastError = error.localizedDescription
            appState.hotkeyMonitoringError = error.localizedDescription
            AppLogger.hotkey.error("Hyper+D monitoring failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshPermissionDiagnostics()
    }

    private func retryHotkeyMonitoring() {
        if !AXIsProcessTrusted() {
            _ = TextInserter.requestAccessibilityPermission()
        }
        requestHotkeyMonitoringIfPossible(prompt: true, restart: true)
    }

    private func requestMicrophonePermission() {
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }
            self.refreshPermissionDiagnostics()
            if !granted {
                self.appState.lastError = "Microphone access is required for dictation."
                self.openPrivacyPane("Privacy_Microphone")
            }
        }
    }

    private func requestInputMonitoringPermission() {
        let granted = CGRequestListenEventAccess()
        refreshPermissionDiagnostics()
        if !granted {
            openPrivacyPane("Privacy_ListenEvent")
        }
    }

    private func requestAccessibilityPermission() {
        let granted = TextInserter.requestAccessibilityPermission()
        refreshPermissionDiagnostics()
        if !granted {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    private func refreshPermissionDiagnostics() {
        appState.microphonePermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        appState.inputMonitoringGranted = CGPreflightListenEventAccess()
        appState.accessibilityGranted = AXIsProcessTrusted()
        appState.hotkeyMonitoringActive = hotkeyManager?.isMonitoring ?? false
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func showOnboarding() {
        refreshPermissionDiagnostics()
        let view = OnboardingView(
            appState: appState,
            onRefreshPermissions: { [weak self] in self?.refreshPermissionDiagnostics() },
            onRequestMicrophone: { [weak self] in self?.requestMicrophonePermission() },
            onRequestInputMonitoring: { [weak self] in self?.requestInputMonitoringPermission() },
            onRequestAccessibility: { [weak self] in self?.requestAccessibilityPermission() },
            onPrepareAndFinish: { [weak self] in self?.prepareAndCompleteOnboarding() }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 590),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Local Dictation"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func prepareAndCompleteOnboarding() {
        refreshPermissionDiagnostics()
        guard appState.microphonePermissionGranted,
              appState.inputMonitoringGranted,
              appState.accessibilityGranted
        else {
            appState.lastError = "Microphone, Input Monitoring, and Accessibility must all be enabled first."
            return
        }

        requestHotkeyMonitoringIfPossible(prompt: false)
        guard appState.hotkeyMonitoringActive else {
            appState.lastError = "Hyper+D is not ready yet. Re-enable Input Monitoring, then return to Local Dictation."
            return
        }

        let complete: (Bool) -> Void = { [weak self] prepared in
            guard let self else { return }
            self.refreshPermissionDiagnostics()
            guard prepared, self.appState.onboardingReady else {
                self.appState.hasCompletedOnboarding = false
                if self.appState.lastError == nil {
                    self.appState.lastError = "Setup is waiting for the selected model and Hyper+D listener to become ready."
                }
                return
            }
            self.appState.hasCompletedOnboarding = true
            UserDefaults.standard.set(true, forKey: Self.onboardingKey)
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
        }

        if appState.engineReady {
            complete(true)
        } else {
            initializeEngine(onCompletion: complete)
        }
    }

    @objc private func toggleFromMenu() {
        switch coordinator.phase {
        case .idle, .failed:
            let now = ProcessInfo.processInfo.systemUptime
            execute(coordinator.hotkeyDown(at: now, profileMode: currentProfileMode()).effects)
            execute(coordinator.hotkeyUp(at: now + 0.001, profileMode: currentProfileMode()).effects)
        case .recording:
            execute(coordinator.finishFromMenu(mode: currentProfileMode()).effects)
        default:
            break
        }
    }

    @objc private func previewFromMenu() {
        execute(coordinator.finishFromMenu(mode: currentProfileMode(), preview: true).effects)
    }

    @objc private func copyLast() {
        guard !appState.lastTranscription.isEmpty else { return }
        textInserter.copyOnly(appState.lastTranscription)
    }

    @objc private func openConfiguration() {
        try? FileManager.default.createDirectory(
            at: Self.configurationDirectory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([Self.configurationDirectory])
    }

    @objc private func openHistory() {
        historyRepasteDestination = DictationDestination.captureFrontmost()
        historyWindow?.show()
    }

    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(
            appState: appState,
            audioDeviceManager: audioDeviceManager,
            configurationDirectory: configurationStore.paths.rootDirectory,
            onReloadConfiguration: { [weak self] in self?.loadConfiguration(bootstrap: false) },
            onOpenHistory: { [weak self] in self?.openHistory() },
            onRefreshPermissions: { [weak self] in self?.refreshPermissionDiagnostics() },
            onRetryHotkey: { [weak self] in self?.retryHotkeyMonitoring() },
            onRequestMicrophone: { [weak self] in self?.requestMicrophonePermission() },
            onOpenMicrophone: { [weak self] in self?.openPrivacyPane("Privacy_Microphone") },
            onOpenInputMonitoring: { [weak self] in self?.openPrivacyPane("Privacy_ListenEvent") },
            onOpenAccessibility: { [weak self] in self?.openPrivacyPane("Privacy_Accessibility") },
            onImportRaycastVocabulary: { [weak self] text in
                self?.importRaycastVocabulary(text)
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 646, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Local Dictation Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func importRaycastVocabulary(_ input: String) {
        let alert = NSAlert()
        do {
            let result = try RaycastVocabularyImporter(
                paths: configurationStore.paths
            ).importCommaSeparated(input)
            loadConfiguration(bootstrap: false)
            appState.raycastVocabularyImportText = ""
            alert.messageText = "Vocabulary imported"
            alert.informativeText = "Added \(result.importedCount) phrase(s); the personal pack now contains \(result.totalCount)."
            alert.alertStyle = .informational
        } catch {
            alert.messageText = "Vocabulary was not imported"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
        }
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateMenu(for phase: DictationPhase) {
        switch phase {
        case .idle, .failed:
            recordingMenuItem?.title = "Start Dictation"
            recordingMenuItem?.isEnabled = true
            previewMenuItem?.isHidden = true
        case .recording:
            recordingMenuItem?.title = "Finish Dictation"
            recordingMenuItem?.isEnabled = true
            previewMenuItem?.isHidden = false
        default:
            recordingMenuItem?.title = phase.rawValue.capitalized
            recordingMenuItem?.isEnabled = false
            previewMenuItem?.isHidden = true
        }
    }

    private func updateStatusIcon(for phase: DictationPhase) {
        statusItem.button?.image = switch phase {
        case .recording: MenuBarIcon.createRecordingFrame(2)
        case .failed: MenuBarIcon.createError()
        case .finalizing, .polishing, .previewing, .pasting: MenuBarIcon.createTranscribing()
        case .idle: MenuBarIcon.create()
        }
    }

    private func updateEngineMenuItem() {
        switch appState.transcriptionEngine {
        case .parakeet:
            engineMenuItem?.title = "Engine: \(appState.parakeetModel.displayName)"
        case .whisperKit:
            engineMenuItem?.title = "Engine: WhisperKit \(appState.whisperModel.displayName)"
        }
    }

    private func cleanupOrphanedTemporaryAudio() {
        let directory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix("local_dictation_recording_") {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

private enum LocalDictationError: LocalizedError {
    case engineUnavailable

    var errorDescription: String? {
        switch self {
        case .engineUnavailable: "The local speech model is not ready yet"
        }
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
