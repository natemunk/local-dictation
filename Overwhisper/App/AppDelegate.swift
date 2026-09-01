import AppKit
import AVFoundation
import Combine
import SwiftUI

enum AppEnvironment {
    static let isDevBuild = Bundle.main.bundleIdentifier == nil
}

private struct ActiveDictationSession {
    let token: DictationSessionToken
    let startedAt: Date
    let engine: (any TranscriptionEngine)?
    let streamingTranscriber: (any StreamingTranscriber)?
    let asrSelection: ASRSelection
    var state: DictationPhase = .recording
    var destination: DictationDestination?
    var profile: DictationProfile
    var rawText = ""
    var deliveredText = ""
    var historyID: UUID?
    var refinementStatus: HistoryRefinementStatus = .notRequested
    var asrOutcome = "final"
    var refinerBackend: String?
    var refinementOutcome: String?
    var validationFailureKind: String?
    var refinementError: String?
    var stoppedAt: Date?
    var pastedRaw = false
    var cleanupMode: CleanupMode = .clean
    var deliveryCommitted = false
    var interleavedTyping = false
    var cancellationRequested = false
    var warnedAtTenMinutes = false
    var durationCapTriggered = false
    var audioURL: URL?
    var finalizationTask: Task<Void, Never>?
    var streamingStartTask: Task<AsyncStream<TranscriptUpdate>?, Never>?
    var streamingUpdatesTask: Task<Void, Never>?
    var captureWatchdog: Task<Void, Never>?
    var finalizationWatchdog: Task<Void, Never>?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private let coordinator = DictationCoordinator(tapHoldThreshold: 0.350)
    private let configurationStore = ConfigurationStore()
    private let pasteAgainQueue = SerializedPasteAgainQueue()
    private var configuration = ConfigurationSnapshot.typedDefaults
    private var profileResolver = ProfileResolver(catalog: .nativeDefaults)
    private var historyStore: HistoryStore?
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var audioRecorder: AudioRecorder!
    private var audioDeviceManager: AudioDeviceManager!
    private var overlayWindow: OverlayWindow!
    private var previewWindow: PreviewWindowController!
    private var textInserter: TextInserter!
    private var engineCoordinator: EngineCoordinator!
    private var transcriptionEngine: (any TranscriptionEngine)?
    private var streamingTranscriber: (any StreamingTranscriber)?

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var historyWindow: HistoryWindowController?
    private var recordingMenuItem: NSMenuItem?
    private var previewMenuItem: NSMenuItem?
    private var engineMenuItem: NSMenuItem?
    private var remoteMenuItem: NSMenuItem?
    private var lastTextMenuItem: NSMenuItem?
    private var pasteLastMenuItem: NSMenuItem?

    private var cancellables = Set<AnyCancellable>()
    private var engineTask: Task<Void, Never>?
    private var historyMaintenanceTask: Task<Void, Never>?
    private var engineReloadPending = false
    private var historyRepasteDestination: DictationDestination?
    private var activeSession: ActiveDictationSession?

    private static let onboardingKey = "LocalDictation.hasCompletedOnboarding.v1"
    private static let configurationDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/local-dictation", isDirectory: true)
    private static let fallbackCompiledVocabulary = (
        try? VocabularyCatalog.nativeDefaults
            .selection(including: [])
            .compileForCleanup()
    ) ?? .empty

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
        engineTask?.cancel()
        historyMaintenanceTask?.cancel()
        pasteAgainQueue.cancelPending()
        if let session = activeSession {
            session.finalizationTask?.cancel()
            session.streamingStartTask?.cancel()
            session.streamingUpdatesTask?.cancel()
            session.captureWatchdog?.cancel()
            session.finalizationWatchdog?.cancel()
            if let streamingTranscriber = session.streamingTranscriber {
                Task { await streamingTranscriber.cancel() }
            }
        }
        hotkeyManager?.stop()
        if audioRecorder?.isRecording == true { audioRecorder.cancelRecording() }
        audioDeviceManager?.shutdown()
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
        audioRecorder.onCallbackLoss = { [weak self] action in
            self?.handleAudioCallbackLoss(action)
        }
        audioRecorder.onCaptureFailure = { [weak self] message in
            self?.handleAudioCaptureFailure(message)
        }
        audioDeviceManager = AudioDeviceManager()
        overlayWindow = OverlayWindow(appState: appState) { [weak self] in
            self?.cancelFromUI()
        }
        let clipboardState = appState
        textInserter = TextInserter(
            privateClipboardMode: { [weak clipboardState] in
                clipboardState?.privateClipboardMode ?? false
            }
        )
        let modelStore = OwnedModelStore()
        engineCoordinator = EngineCoordinator(
            initialSelection: appState.asrSelection,
            store: modelStore,
            backend: ProductionEngineLifecycleBackend(appState: appState)
        )
        if let historyStore {
            historyWindow = HistoryWindowController(
                store: historyStore,
                onCopy: { [weak self] text in self?.textInserter.copyOnly(text) },
                onRepaste: { [weak self] text in self?.repasteHistoryText(text) },
                onAddVocabularyCorrection: { [weak self] entry in
                    self?.promptForVocabularyCorrection(from: entry)
                }
            )
        }
        previewWindow = PreviewWindowController(
            onDeliver: { [weak self] token, text in self?.deliverPreview(token: token, text: text) },
            onCopy: { [weak self] token, text in self?.copyPreview(token: token, text: text) },
            onCancel: { [weak self] token in self?.cancelPreview(token: token) }
        )
        hotkeyManager = HotkeyManager(
            coordinator: coordinator,
            // The global tap must not perform Accessibility work. The exact
            // destination profile is resolved after finish, outside the tap;
            // Option+Enter still carries an explicit Literal override.
            profileMode: { .clean },
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

        appState.$experimentalModelCleanupEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateRefinerPrivacyState()
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

        appState.$asrSelection
        .dropFirst()
        .removeDuplicates()
        .sink { [weak self] _ in
            self?.initializeEngine()
            self?.updateEngineMenuItem()
        }
        .store(in: &cancellables)

        engineCoordinator.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.appState.isDownloadingModel = status.phase == .downloading
                    || status.phase == .repairing
                self.appState.isInitializingEngine = [
                    .checking, .downloading, .validating, .preparing, .repairing,
                ].contains(status.phase)
                self.appState.modelDownloadProgress = status.progress ?? 0
                self.appState.currentlyDownloadingModel = self.appState.isDownloadingModel
                    ? status.selection.displayName
                    : nil
                if status.phase == .failed {
                    self.appState.lastError = status.lastError
                }
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
        guard appState.hasCompletedOnboarding else { return }
        requestHotkeyMonitoringIfPossible(prompt: false)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let healthy = await self.engineCoordinator.healthCheck(
                selection: self.appState.asrSelection
            )
            if !healthy || !self.appState.engineReady || self.transcriptionEngine == nil {
                self.initializeEngine()
            }
        }
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
        let pasteLast = NSMenuItem(
            title: "Paste Last Dictation",
            action: #selector(pasteLast),
            keyEquivalent: ""
        )
        pasteLast.target = self
        pasteLast.isEnabled = false
        menu.addItem(pasteLast)
        pasteLastMenuItem = pasteLast

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
            case .startCapture(let token):
                beginCapture(token: token)
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.startAudioCapture(token: token)
                }
            case .finish(let request):
                beginFinalization(request)
                Task { @MainActor [weak self] in
                    await Task.yield()
                    await self?.finishCapture(request)
                }
            case .cancel(let token):
                guard matchesActiveSession(token) else { continue }
                updateSession(token) {
                    $0.cancellationRequested = true
                    $0.finalizationTask?.cancel()
                    $0.streamingStartTask?.cancel()
                    $0.streamingUpdatesTask?.cancel()
                }
                Task { @MainActor [weak self] in
                    await Task.yield()
                    await self?.cancelActiveSession(token: token)
                }
            case .interleavedTypingChanged(let token, let detected):
                guard isCurrent(token) else { continue }
                updateSession(token) { $0.interleavedTyping = detected }
                if detected {
                    if appState.phase == .recording {
                        appState.setInterleavedTyping()
                    } else {
                        appState.interleavedTyping = true
                    }
                }
            }
        }
    }

    private func isCurrent(_ token: DictationSessionToken) -> Bool {
        guard let session = activeSession else { return false }
        return session.token == token && !session.cancellationRequested
    }

    private func matchesActiveSession(_ token: DictationSessionToken) -> Bool {
        activeSession?.token == token
    }

    @discardableResult
    private func updateSession(
        _ token: DictationSessionToken,
        _ update: (inout ActiveDictationSession) -> Void
    ) -> Bool {
        guard var session = activeSession, session.token == token else { return false }
        update(&session)
        activeSession = session
        return true
    }

    private func beginCapture(token: DictationSessionToken) {
        guard coordinator.owns(token) else { return }

        if let prior = activeSession, prior.token != token {
            retireRuntime(prior)
        }

        let placeholderProfile = ProfileCatalog.nativeDefaults["default"]!
        activeSession = ActiveDictationSession(
            token: token,
            startedAt: Date(),
            engine: transcriptionEngine,
            streamingTranscriber: streamingTranscriber,
            asrSelection: appState.asrSelection,
            profile: placeholderProfile
        )

        // These happen before permission checks or model work so the key-down
        // feedback path stays under the 100 ms product gate.
        appState.beginRecording()
        overlayWindow.show(position: appState.overlayPosition, token: token)

        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  let self,
                  self.isCurrent(token),
                  !self.audioRecorder.isRecording
            else { return }
            self.failSession(token: token, "The microphone did not start within two seconds.")
        }
        updateSession(token) { $0.captureWatchdog = watchdog }
    }

    private func startAudioCapture(token: DictationSessionToken) {
        guard isCurrent(token), coordinator.owns(token) else { return }
        guard !audioRecorder.isRecording else {
            failSession(token: token, "The microphone is already owned by another recording.")
            return
        }

        guard activeSession?.engine != nil else {
            failSession(token: token, "The local speech model is still preparing. Try Hyper+D again when setup finishes.")
            return
        }

        do {
            let samples = try audioRecorder.startRecording()
            updateSession(token) {
                $0.captureWatchdog?.cancel()
                $0.captureWatchdog = nil
            }
            if activeSession?.streamingTranscriber == nil {
                appState.overlayMessage = "Listening · live text unavailable"
            } else {
                startStreamingUpdates(samples: samples, token: token)
            }
        } catch {
            failSession(token: token, "Could not start the microphone: \(error.localizedDescription)")
        }
    }

    private func startStreamingUpdates(
        samples: AsyncStream<AudioChunk>,
        token: DictationSessionToken
    ) {
        guard let session = activeSession,
              session.token == token,
              let streamingTranscriber = session.streamingTranscriber
        else { return }
        session.streamingStartTask?.cancel()
        session.streamingUpdatesTask?.cancel()

        let startTask = Task<AsyncStream<TranscriptUpdate>?, Never> {
            do {
                return try await streamingTranscriber.start(samples: samples)
            } catch {
                AppLogger.transcription.error(
                    "Live transcription could not start: \(error.localizedDescription)"
                )
                if self.isCurrent(token),
                   self.appState.phase == .recording,
                   !self.appState.interleavedTyping {
                    self.appState.overlayMessage = "Listening · live text unavailable"
                }
                return nil
            }
        }
        updateSession(token) { $0.streamingStartTask = startTask }
        let updatesTask = Task { @MainActor [weak self] in
            guard let updates = await startTask.value else { return }
            for await update in updates {
                guard !Task.isCancelled,
                      let self,
                      self.isCurrent(token)
                else { return }
                self.appState.liveTranscript = LiveTranscript(
                    finalized: update.finalized,
                    volatile: update.volatile
                )
            }
            guard !Task.isCancelled,
                  let self,
                  self.isCurrent(token),
                  self.appState.phase == .recording,
                  !self.appState.interleavedTyping
            else { return }
            self.appState.overlayMessage = "Listening · live text unavailable"
        }
        updateSession(token) { $0.streamingUpdatesTask = updatesTask }
    }

    private func finishStreamingTranscript(token: DictationSessionToken) async -> FinalTranscript? {
        guard let session = activeSession,
              session.token == token,
              let streamingTranscriber = session.streamingTranscriber,
              let streamingStartTask = session.streamingStartTask,
              await streamingStartTask.value != nil,
              isCurrent(token)
        else {
            updateSession(token) {
                $0.streamingStartTask = nil
                $0.streamingUpdatesTask?.cancel()
                $0.streamingUpdatesTask = nil
            }
            return nil
        }

        defer {
            updateSession(token) {
                $0.streamingStartTask = nil
                $0.streamingUpdatesTask = nil
            }
        }
        do {
            let final = try await streamingTranscriber.finish()
            guard isCurrent(token) else { return nil }
            appState.liveTranscript = LiveTranscript(finalized: final.text, volatile: "")
            return final
        } catch {
            AppLogger.transcription.error(
                "Live transcription did not produce a final result: \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func cancelStreamingSession(token: DictationSessionToken) {
        guard let session = activeSession, session.token == token else { return }
        session.streamingStartTask?.cancel()
        session.streamingUpdatesTask?.cancel()
        updateSession(token) {
            $0.streamingStartTask = nil
            $0.streamingUpdatesTask = nil
        }
        guard let streamingTranscriber = session.streamingTranscriber else { return }
        Task { await streamingTranscriber.cancel() }
    }

    private func beginFinalization(_ request: DictationFinishRequest) {
        guard isCurrent(request.token) else { return }
        updateSession(request.token) {
            $0.state = .finalizing
            $0.stoppedAt = Date()
        }
        appState.endRecordingClock()
        appState.phase = .finalizing
        appState.overlayMessage = "Finalizing"
    }

    private func finishCapture(_ request: DictationFinishRequest) async {
        guard isCurrent(request.token) else { return }
        guard audioRecorder.isRecording else {
            failSession(token: request.token, "The microphone stopped before finalization could begin.")
            return
        }

        let destination = DictationDestination.captureFrontmost()
        let initialProfile = resolveProfile(for: destination).profile
        updateSession(request.token) {
            $0.destination = destination
            $0.profile = initialProfile
        }
        appState.activeProfileName = profileDisplayName(initialProfile)

        let audioURL: URL
        do {
            audioURL = try await audioRecorder.stopRecording()
            updateSession(request.token) { $0.audioURL = audioURL }
        } catch {
            failSession(token: request.token, "Could not finish the recording: \(error.localizedDescription)")
            return
        }

        // Destination is intentionally resolved at finish so app/Space
        // switching remains supported. A secure target is terminal: cancel
        // optional EOU work, delete the WAV, and create no ASR/history/clipboard
        // artifact for this session.
        if destination?.isSecureField == true {
            cancelStreamingSession(token: request.token)
            if FileManager.default.fileExists(atPath: audioURL.path) {
                try? FileManager.default.removeItem(at: audioURL)
            }
            updateSession(request.token) { $0.audioURL = nil }
            appState.liveTranscript = LiveTranscript()
            appState.overlayMessage = "Secure field · recording discarded"
            completeSession(token: request.token, toastDuration: .milliseconds(250))
            return
        }

        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self, self.isCurrent(request.token) else { return }
            self.activeSession?.finalizationTask?.cancel()
            self.failSession(token: request.token, "Transcription exceeded its two-minute safety deadline. The recording was not pasted.")
        }
        updateSession(request.token) { $0.finalizationWatchdog = watchdog }

        let finalizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if FileManager.default.fileExists(atPath: audioURL.path) {
                    try? FileManager.default.removeItem(at: audioURL)
                }
                if self.isCurrent(request.token) {
                    self.updateSession(request.token) {
                        $0.audioURL = nil
                        $0.finalizationTask = nil
                        $0.finalizationWatchdog?.cancel()
                        $0.finalizationWatchdog = nil
                    }
                }
            }

            let started = ContinuousClock.now
            let streamingFinalTask = Task { [weak self] in
                await self?.finishStreamingTranscript(token: request.token)
            }
            do {
                let resolvedProfile = self.resolveProfile(for: destination)
                try Task.checkCancellation()
                guard self.isCurrent(request.token) else { return }
                self.updateSession(request.token) { $0.profile = resolvedProfile.profile }
                self.appState.activeProfileName = self.profileDisplayName(resolvedProfile.profile)
                self.appState.customVocabulary = self.asrVocabularyBias(for: resolvedProfile.profile)

                guard let engine = self.activeSession?.engine else {
                    throw LocalDictationError.engineUnavailable
                }
                let raw = try await engine.transcribe(audioURL: audioURL)
                let decision = ASRFinalizationPolicy.authoritative(raw)
                // Batch ASR is authoritative. Never wait for a result that will
                // be discarded; cancel optional EOU work immediately.
                streamingFinalTask.cancel()
                self.cancelStreamingSession(token: request.token)
                try Task.checkCancellation()
                guard self.isCurrent(request.token) else { return }
                let asrLatency = started.duration(to: .now).seconds
                self.retainDebugRecordingIfEnabled(
                    at: audioURL,
                    transcript: raw.text,
                    latency: asrLatency,
                    error: nil,
                    token: request.token
                )
                await self.handleRawTranscript(
                    decision.transcript,
                    request: request,
                    asrLatency: asrLatency
                )
            } catch is CancellationError {
                streamingFinalTask.cancel()
                return
            } catch {
                guard !Task.isCancelled, self.isCurrent(request.token) else { return }
                let fallback = ASRFinalizationPolicy.recoverFromEOU(
                    self.appState.liveTranscript.displayed
                )
                streamingFinalTask.cancel()
                self.cancelStreamingSession(token: request.token)
                if let fallback {
                    assert(fallback.delivery == .previewOnly)
                    assert(!fallback.commandsAllowed)
                    let latency = started.duration(to: .now).seconds
                    self.retainDebugRecordingIfEnabled(
                        at: audioURL,
                        transcript: fallback.transcript.text,
                        latency: latency,
                        error: "Batch ASR failed; opened the local EOU transcript in preview",
                        token: request.token
                    )
                    await self.handleEOUFallback(
                        fallback.transcript,
                        batchError: error,
                        token: request.token,
                        asrLatency: latency
                    )
                    return
                }
                self.retainDebugRecordingIfEnabled(
                    at: audioURL,
                    transcript: "",
                    latency: started.duration(to: .now).seconds,
                    error: error.localizedDescription,
                    token: request.token
                )
                self.failSession(token: request.token, "Transcription failed: \(error.localizedDescription)")
            }
        }
        updateSession(request.token) { $0.finalizationTask = finalizationTask }
    }

    /// A 120M EOU preview is useful recovery text, not authoritative ASR. It
    /// bypasses commands and cleanup and can only enter an editable preview.
    private func handleEOUFallback(
        _ raw: FinalTranscript,
        batchError: Error,
        token: DictationSessionToken,
        asrLatency: Double
    ) async {
        guard isCurrent(token), !raw.text.isEmpty else { return }
        updateSession(token) { session in
            session.rawText = raw.text
            session.deliveredText = raw.text
            session.cleanupMode = .literal
            session.refinementStatus = .notRequested
            session.asrOutcome = "eou_preview_fallback"
            session.refinerBackend = "none"
            session.refinementOutcome = "not_requested"
            session.pastedRaw = true
        }
        appState.lastTranscription = raw.text
        lastTextMenuItem?.isEnabled = true
        pasteLastMenuItem?.isEnabled = true

        guard await saveRawHistory(
            token: token,
            mode: .literal,
            asrLatency: asrLatency,
            unrecognizedCommands: []
        ) else {
            failSession(
                token: token,
                "Batch transcription failed and the EOU recovery transcript could not be saved. Nothing was pasted."
            )
            return
        }

        guard let historyStore,
              let id = activeSession?.historyID
        else {
            failSession(token: token, "EOU recovery history is unavailable. Nothing was pasted.")
            return
        }
        do {
            _ = try await historyStore.finalize(
                id: id,
                with: HistoryFinalization(
                    polishedText: raw.text,
                    refinementStatus: .notRequested,
                    deliveryStatus: .pending,
                    refinementLatency: nil,
                    totalLatency: activeSession.map {
                        Date().timeIntervalSince($0.startedAt)
                    },
                    error: "Batch ASR failed; EOU preview fallback: \(batchError.localizedDescription)",
                    asrSelection: activeSession?.asrSelection.rawValue,
                    asrOutcome: "eou_preview_fallback",
                    refinerBackend: "none",
                    refinementOutcome: "not_requested"
                )
            )
        } catch {
            failSession(
                token: token,
                "EOU recovery history could not be finalized. Nothing was pasted."
            )
            return
        }
        showPreview(token: token)
    }

    private func handleRawTranscript(
        _ raw: FinalTranscript,
        request: DictationFinishRequest,
        asrLatency: Double
    ) async {
        let token = request.token
        guard !Task.isCancelled, isCurrent(token) else { return }
        updateSession(token) { $0.rawText = raw.text }
        guard !raw.text.isEmpty else {
            failSession(token: token, "No speech was detected. Nothing was pasted.")
            return
        }

        appState.lastTranscription = raw.text
        lastTextMenuItem?.isEnabled = true
        pasteLastMenuItem?.isEnabled = true

        guard let profile = activeSession?.profile else { return }
        let cleanupMode: CleanupMode = request.mode == .literal
            || profile.mode == .literal
            || !profile.cleanupEnabled
            ? .literal
            : .clean
        updateSession(token) { $0.cleanupMode = cleanupMode }
        let commandAnalysis = cleanupMode == .clean
            ? CleanupCommandProcessor().analyze(raw)
            : CleanupCommandResult(
                text: raw.text,
                recognizedCommands: [],
                unrecognizedCommandCandidates: []
            )
        guard await saveRawHistory(
            token: token,
            mode: cleanupMode,
            asrLatency: asrLatency,
            unrecognizedCommands: commandAnalysis.unrecognizedCommandCandidates.map(\.phrase)
        ) else {
            updateSession(token) { $0.deliveredText = raw.text }
            let copied = textInserter.copyOnly(raw.text)
            failSession(
                token: token,
                copied
                    ? "Raw history could not be saved. The transcript was copied to the clipboard; nothing was pasted."
                    : "Raw history and clipboard writes both failed. Nothing was pasted."
            )
            return
        }

        let refinementStarted = Date()
        let refinerBackend = cleanupMode == .clean
            ? configuredRefinerBackendName()
            : "none"
        if cleanupMode == .clean {
            guard coordinator.transition(token: token, to: .polishing) else { return }
            updateSession(token) { $0.state = .polishing }
            appState.phase = .polishing
            appState.overlayMessage = "Polishing"
        }

        do {
            let result = try await makeCleanupPipeline(for: profile).process(
                raw,
                mode: cleanupMode
            )
            try Task.checkCancellation()
            guard isCurrent(token) else { return }
            updateSession(token) { session in
                session.deliveredText = result.text
                session.refinerBackend = refinerBackend
                session.validationFailureKind = nil
                session.refinementError = nil
                switch result.outcome {
                case .skippedLiteralMode:
                    session.refinementStatus = .notRequested
                    session.refinementOutcome = "not_requested"
                    session.pastedRaw = false
                case .accepted:
                    session.refinementStatus = .succeeded
                    session.refinementOutcome = refinerBackend == "deterministic"
                        ? "deterministic"
                        : "accepted"
                    session.pastedRaw = false
                case .deterministicFallback(let reason):
                    session.refinementStatus = .failed
                    session.refinementOutcome = "deterministic_fallback"
                    switch reason {
                    case .refinerFailure(let message):
                        session.refinementError = message
                    case .validationFailure(let failure):
                        session.refinementError = failure.description
                        session.validationFailureKind = Self.historyValidationFailureKind(failure)
                    }
                    session.pastedRaw = true
                }
            }
            await finalizeHistoryBeforeDelivery(
                token: token,
                refinementLatency: Date().timeIntervalSince(refinementStarted)
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(token) else { return }
            updateSession(token) {
                $0.deliveredText = $0.rawText
                $0.refinementStatus = cleanupMode == .literal ? .notRequested : .failed
                $0.refinerBackend = refinerBackend
                $0.refinementOutcome = cleanupMode == .literal
                    ? "not_requested"
                    : "failed"
                $0.refinementError = error.localizedDescription
                $0.pastedRaw = cleanupMode == .clean
            }
            if cleanupMode == .clean {
                await markHistoryPolishFailed(
                    token: token,
                    error.localizedDescription,
                    refinementLatency: Date().timeIntervalSince(refinementStarted)
                )
            } else {
                await finalizeHistoryBeforeDelivery(
                    token: token,
                    refinementLatency: Date().timeIntervalSince(refinementStarted)
                )
            }
        }

        AppLogger.transcription.info("Local ASR complete in \(String(format: "%.3f", asrLatency)) seconds")
        guard !Task.isCancelled, isCurrent(token), let session = activeSession else { return }
        if request.delivery == .preview {
            showPreview(token: token)
        } else {
            await pasteCurrentText(
                token: token,
                showRawLabel: session.pastedRaw || cleanupMode == .literal
            )
        }
    }

    private func showPreview(token: DictationSessionToken) {
        guard let session = activeSession,
              session.token == token,
              coordinator.transition(token: token, to: .previewing)
        else { return }
        updateSession(token) { $0.state = .previewing }
        appState.phase = .previewing
        appState.overlayMessage = "Preview"
        overlayWindow.hide(token: token)
        previewWindow.show(
            text: session.deliveredText,
            rawText: session.rawText,
            isRemoteRefiner: appState.isRemoteRefiner,
            token: token
        )
    }

    private func pasteCurrentText(
        token: DictationSessionToken,
        showRawLabel: Bool,
        reactivateDestination: Bool = false
    ) async {
        guard !Task.isCancelled,
              let session = activeSession,
              session.token == token,
              coordinator.transition(token: token, to: .pasting)
        else { return }
        updateSession(token) { $0.state = .pasting }
        appState.phase = .pasting
        appState.overlayMessage = "Pasting"
        overlayWindow.show(position: appState.overlayPosition, token: token)
        let insertionText = safeAutomaticInsertionText(
            session.deliveredText,
            destination: session.destination
        )
        let outcome = await textInserter.insertText(
            insertionText,
            destination: session.destination,
            reactivateDestination: reactivateDestination
        )
        guard isCurrent(token) else { return }

        switch outcome {
        case .pasteEventSent:
            appState.overlayMessage = showRawLabel ? "Paste sent · raw" : "Paste sent"
            await updateHistoryDelivery(
                token: token,
                status: .pasteEventSent,
                deliveredText: insertionText
            )
            updateSession(token) { $0.deliveryCommitted = true }
        case .clipboardOnly(let reason):
            appState.overlayMessage = "Copied to clipboard"
            appState.lastError = reason
            await updateHistoryDelivery(
                token: token,
                status: .clipboardOnly,
                deliveredText: insertionText,
                error: reason
            )
            updateSession(token) { $0.deliveryCommitted = true }
        case .historyOnly(let reason):
            appState.overlayMessage = "Saved to history"
            appState.lastError = reason
            await updateHistoryDelivery(
                token: token,
                status: .historyOnly,
                deliveredText: insertionText,
                error: reason
            )
            updateSession(token) { $0.deliveryCommitted = true }
        case .cancelled:
            await updateHistoryDelivery(
                token: token,
                status: .cancelled,
                deliveredText: insertionText,
                error: "Insertion was cancelled"
            )
            return
        }
        appState.lastTranscription = insertionText
        completeSession(token: token, toastDuration: .milliseconds(250))
    }

    private func deliverPreview(token: DictationSessionToken, text: String) {
        guard isCurrent(token) else { return }
        updateSession(token) { $0.deliveredText = text }
        previewWindow.close(token: token)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let session = self.activeSession, session.token == token else { return }
            await self.pasteCurrentText(
                token: token,
                showRawLabel: session.pastedRaw || session.cleanupMode == .literal,
                reactivateDestination: true
            )
        }
        updateSession(token) { $0.finalizationTask = task }
    }

    private func copyPreview(token: DictationSessionToken, text: String) {
        guard isCurrent(token) else { return }
        updateSession(token) {
            $0.deliveredText = text
            $0.deliveryCommitted = true
        }
        if !textInserter.copyOnly(text) {
            appState.lastError = "Could not copy the preview text to the clipboard"
        }
        previewWindow.close(token: token)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.updateHistoryDelivery(
                token: token,
                status: .previewed,
                deliveredText: text
            )
            guard self.isCurrent(token) else { return }
            self.completeSession(token: token)
        }
    }

    private func cancelPreview(token: DictationSessionToken) {
        guard isCurrent(token) else { return }
        execute(coordinator.escapePressed().effects)
    }

    private func cancelFromUI() {
        execute(coordinator.escapePressed().effects)
    }

    private func cancelActiveSession(token: DictationSessionToken) async {
        guard let session = activeSession, session.token == token else { return }
        let pasteMayHaveBeenCommitted = appState.phase == .pasting
        session.finalizationTask?.cancel()
        cancelStreamingSession(token: token)
        if audioRecorder.isRecording { audioRecorder.cancelRecording() }
        if !session.deliveryCommitted,
           let historyID = session.historyID,
           let historyStore {
            _ = try? await historyStore.updateDelivery(
                id: historyID,
                with: HistoryDeliveryUpdate(
                    status: .cancelled,
                    deliveredText: session.deliveredText.isEmpty ? nil : session.deliveredText,
                    totalLatency: Date().timeIntervalSince(session.startedAt),
                    error: pasteMayHaveBeenCommitted
                        ? "Cancelled while the paste event status was uncertain"
                        : "Dictation was cancelled before delivery"
                )
            )
        }
        previewWindow.close(token: token)
        completeSession(token: token)
    }

    private func failSession(token: DictationSessionToken, _ message: String) {
        guard let session = activeSession,
              session.token == token,
              !session.cancellationRequested
        else { return }
        updateSession(token) {
            $0.captureWatchdog?.cancel()
            $0.captureWatchdog = nil
            $0.finalizationWatchdog?.cancel()
            $0.finalizationWatchdog = nil
        }
        cancelStreamingSession(token: token)
        if audioRecorder?.isRecording == true { audioRecorder.cancelRecording() }
        _ = coordinator.transition(token: token, to: .failed)
        updateSession(token) { $0.state = .failed }
        appState.endRecordingClock()
        appState.phase = .failed
        appState.lastError = message
        appState.overlayMessage = "Error"
        overlayWindow.show(position: appState.overlayPosition, token: token)
        retireRuntime(session, hideOverlay: false)
        _ = coordinator.complete(token: token)
        activeSession = nil

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.overlayWindow.hide(token: token)
            if self.activeSession == nil, self.appState.phase == .failed {
                self.appState.resetSessionUI()
                if self.engineReloadPending { self.initializeEngine() }
            }
        }
    }

    private func completeSession(
        token: DictationSessionToken,
        toastDuration: Duration? = nil
    ) {
        guard let session = activeSession, session.token == token else { return }
        let toastMessage = appState.overlayMessage
        retireRuntime(session, hideOverlay: toastDuration == nil)
        _ = coordinator.complete(token: token)
        activeSession = nil
        appState.resetSessionUI()
        if engineReloadPending { initializeEngine() }
        guard let toastDuration else { return }
        appState.overlayMessage = toastMessage
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: toastDuration)
            guard let self else { return }
            self.overlayWindow.hide(token: token)
            if self.activeSession == nil {
                self.appState.overlayMessage = "Listening"
            }
        }
    }

    private func retireRuntime(
        _ session: ActiveDictationSession,
        hideOverlay: Bool = true
    ) {
        session.finalizationTask?.cancel()
        session.streamingStartTask?.cancel()
        session.streamingUpdatesTask?.cancel()
        session.captureWatchdog?.cancel()
        session.finalizationWatchdog?.cancel()
        if let streamingTranscriber = session.streamingTranscriber {
            Task { await streamingTranscriber.cancel() }
        }
        if let audioURL = session.audioURL,
           FileManager.default.fileExists(atPath: audioURL.path) {
            try? FileManager.default.removeItem(at: audioURL)
        }
        previewWindow.close(token: session.token)
        if hideOverlay { overlayWindow.hide(token: session.token) }
    }

    private func handleDuration(_ duration: TimeInterval) {
        guard appState.phase == .recording,
              let token = activeSession?.token
        else { return }
        if duration >= 600, activeSession?.warnedAtTenMinutes == false {
            updateSession(token) { $0.warnedAtTenMinutes = true }
            appState.overlayMessage = "10 minutes · preview at 15"
        }
        if duration >= TimeInterval(configuration.app.maximumRecordingDurationSeconds),
           activeSession?.durationCapTriggered == false
        {
            updateSession(token) { $0.durationCapTriggered = true }
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

    private func handleAudioCallbackLoss(_ action: AudioCallbackLossAction) {
        guard let token = activeSession?.token,
              appState.phase == .recording
        else { return }

        switch action {
        case .none:
            return
        case .finishInPreview:
            appState.overlayMessage = "Microphone disconnected · opening preview"
            execute(
                coordinator.finishFromMenu(
                    mode: currentProfileMode(),
                    preview: true
                ).effects
            )
        case .fail:
            failSession(
                token: token,
                "The microphone stopped before any usable audio was captured."
            )
        }
    }

    private func handleAudioCaptureFailure(_ message: String) {
        guard let token = activeSession?.token,
              appState.phase == .recording
        else { return }
        failSession(token: token, "Audio capture failed: \(message)")
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
            defaultProfileID: configuration.app.defaultProfileID
        )
        coordinator.updateTapHoldThreshold(
            Double(configuration.app.tapHoldThresholdMilliseconds) / 1_000
        )
        let preferences = UserDefaults.standard
        if preferences.object(forKey: LocalDictationPreferenceKey.retainDebugAudio) == nil,
           configuration.app.debugAudioRetentionEnabled {
            // One-time migration from the legacy TOML flag. UserDefaults is
            // the sole owner after this value has been materialized.
            preferences.set(true, forKey: LocalDictationPreferenceKey.retainDebugAudio)
        }
        appState.retainDebugAudio = preferences.bool(
            forKey: LocalDictationPreferenceKey.retainDebugAudio
        )
        updateRefinerPrivacyState()
        appState.configurationDiagnostic = result.diagnostic?.message
        appState.configurationNotices = result.notices.map(\.message)
        if let historyStore {
            startHistoryMaintenance(for: historyStore)
        }
    }

    private func updateRefinerPrivacyState() {
        appState.isRemoteRefiner = configuredRefinerIsRemote
        remoteMenuItem?.isHidden = !appState.isRemoteRefiner
        statusItem?.button?.toolTip = appState.isRemoteRefiner
            ? "Local Dictation · REMOTE text refiner active"
            : "Local Dictation"
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
            historyStore = store
            startHistoryMaintenance(for: store)
        } catch {
            appState.lastError = "History is unavailable: \(error.localizedDescription)"
        }
    }

    private func startHistoryMaintenance(for store: HistoryStore) {
        historyMaintenanceTask?.cancel()
        let policy = HistoryRetentionPolicy(
            retentionDays: configuration.app.historySuccessRetentionDays
        )
        historyMaintenanceTask = Task { @MainActor [weak self, store] in
            while !Task.isCancelled {
                do {
                    _ = try await store.pruneEntries(policy: policy)
                } catch is CancellationError {
                    return
                } catch {
                    self?.appState.lastError = "History retention failed: \(error.localizedDescription)"
                }

                do {
                    try await Task.sleep(for: .seconds(24 * 60 * 60))
                } catch {
                    return
                }
            }
        }
    }

    private func resolveCurrentProfile() -> ResolvedProfile {
        let destination = DictationDestination.captureFrontmost()
        return resolveProfile(for: destination)
    }

    private func resolveProfile(for destination: DictationDestination?) -> ResolvedProfile {
        if destination?.isTerminal == true,
           let terminal = configuration.profiles["terminal"]
                ?? ProfileCatalog.nativeDefaults["terminal"] {
            return ResolvedProfile(
                profile: TerminalProfilePolicy.enforcingSafety(on: terminal),
                source: .accessibility
            )
        }
        return profileResolver.resolve(profileContext(for: destination))
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

    private func safeAutomaticInsertionText(
        _ text: String,
        destination: DictationDestination?
    ) -> String {
        destination?.isTerminal == true
            ? TerminalOutputSafety.collapseLineBreaks(text)
            : text
    }

    private func selectedVocabulary(for profile: DictationProfile) -> VocabularyPack {
        configuration.vocabulary.selection(including: profile.vocabularyPackIDs)
    }

    private func asrVocabularyBias(for profile: DictationProfile) -> String {
        let vocabulary = selectedVocabulary(for: profile)
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

    private func makeCleanupPipeline(for profile: DictationProfile) -> CleanupPipeline {
        let compiled = configurationStore.compiledVocabulary(forProfileID: profile.id)
            ?? configurationStore.compiledVocabulary(
                forProfileID: configuration.app.defaultProfileID
            )
            ?? Self.fallbackCompiledVocabulary
        return CleanupPipeline(
            compiledVocabulary: compiled,
            refiner: configuredTextRefiner()
        )
    }

    private func configuredTextRefiner() -> any TextRefiner {
        guard appState.experimentalModelCleanupEnabled else {
            return DeterministicRefiner()
        }
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

        return base
    }

    private func configuredRefinerBackendName() -> String {
        guard appState.experimentalModelCleanupEnabled else {
            return "deterministic"
        }
        switch configuration.app.refinerMode {
        case .deterministic:
            return "deterministic"
        case .openAICompatible:
            return configuration.app.refinerEndpoint != nil
                && configuration.app.refinerModel != nil
                ? "openai_compatible"
                : "deterministic"
        case .auto:
            if configuration.app.refinerEndpoint != nil,
               configuration.app.refinerModel != nil {
                return "openai_compatible"
            }
            return SystemAppleFoundationModelAdapter().availability() == .available
                ? "apple_foundation"
                : "deterministic"
        }
    }

    private static func historyValidationFailureKind(
        _ failure: RefinementValidationFailure
    ) -> String {
        switch failure {
        case .invalidCandidateRange:
            "invalid_candidate_range"
        case .invalidProtectedRange:
            "invalid_protected_range"
        case .protectedSpanSourceMismatch:
            "protected_span_source_mismatch"
        case .overlappingProtectedSpans:
            "overlapping_protected_spans"
        case .protectedSpanCountMismatch:
            "protected_span_count_mismatch"
        case .protectedSpanOrderChanged:
            "protected_span_order_changed"
        case .inferredBulletFormatting:
            "inferred_bullet_formatting"
        case .explicitBulletFormattingRemoved:
            "explicit_bullet_formatting_removed"
        case .unexpectedLexicalToken:
            "unexpected_lexical_token"
        case .deletionOutsideCandidate:
            "deletion_outside_candidate"
        case .excessiveLexicalDeletion:
            "excessive_lexical_deletion"
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
        guard appState.experimentalModelCleanupEnabled,
              configuration.app.refinerMode != .deterministic,
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
        error: String?,
        token: DictationSessionToken
    ) {
        guard let session = activeSession,
              session.token == token,
              appState.retainDebugAudio,
              FileManager.default.fileExists(atPath: audioURL.path)
        else { return }

        let selection = session.asrSelection
        let engine = selection.isParakeet ? "FluidAudio Parakeet" : "WhisperKit"
        _ = appState.debugSessionStore.record(
            engine: engine,
            model: selection.modelVariant,
            sourceAudioURL: audioURL,
            recordingDuration: Date().timeIntervalSince(session.startedAt),
            transcribedText: transcript,
            latencySeconds: latency,
            language: "en",
            errorMessage: error
        )
    }

    private func saveRawHistory(
        token: DictationSessionToken,
        mode: CleanupMode,
        asrLatency: TimeInterval,
        unrecognizedCommands: [String]
    ) async -> Bool {
        guard let historyStore,
              let session = activeSession,
              session.token == token
        else {
            appState.lastError = "History is unavailable"
            return false
        }
        let id = token.id
        do {
            _ = try await historyStore.saveRaw(
                HistoryRawCapture(
                    id: id,
                    rawText: session.rawText,
                    destination: HistoryDestination(
                        bundleIdentifier: session.destination?.bundleIdentifier,
                        displayName: session.destination?.applicationName
                    ),
                    mode: mode == .literal ? .literal : .clean,
                    asrLatency: asrLatency,
                    unrecognizedCommandCandidates: unrecognizedCommands,
                    asrSelection: session.asrSelection.rawValue,
                    asrOutcome: session.asrOutcome
                )
            )
            guard let current = activeSession,
                  current.token == token,
                  !current.cancellationRequested
            else {
                _ = try? await historyStore.updateDelivery(
                    id: id,
                    with: HistoryDeliveryUpdate(
                        status: .cancelled,
                        error: "Dictation was cancelled before delivery"
                    )
                )
                return false
            }
            updateSession(token) { $0.historyID = id }
            return true
        } catch {
            if isCurrent(token) {
                appState.lastError = "Could not save raw history: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func finalizeHistoryBeforeDelivery(
        token: DictationSessionToken,
        refinementLatency: TimeInterval
    ) async {
        guard let historyStore,
              let session = activeSession,
              session.token == token,
              let id = session.historyID
        else { return }
        do {
            _ = try await historyStore.finalize(
                id: id,
                with: HistoryFinalization(
                    polishedText: session.deliveredText,
                    refinementStatus: session.refinementStatus,
                    deliveryStatus: .pending,
                    refinementLatency: refinementLatency,
                    totalLatency: Date().timeIntervalSince(session.startedAt),
                    error: session.refinementError,
                    asrSelection: session.asrSelection.rawValue,
                    asrOutcome: session.asrOutcome,
                    refinerBackend: session.refinerBackend,
                    refinementOutcome: session.refinementOutcome,
                    validationFailureKind: session.validationFailureKind
                )
            )
        } catch {
            if isCurrent(token) {
                appState.lastError = "Could not update history: \(error.localizedDescription)"
            }
        }
    }

    private func markHistoryPolishFailed(
        token: DictationSessionToken,
        _ error: String,
        refinementLatency: TimeInterval? = nil
    ) async {
        guard let historyStore,
              let session = activeSession,
              session.token == token,
              let id = session.historyID
        else { return }
        do {
            _ = try await historyStore.markPolishFailed(
                id: id,
                error: error,
                refinementLatency: refinementLatency,
                totalLatency: Date().timeIntervalSince(session.startedAt),
                asrSelection: session.asrSelection.rawValue,
                asrOutcome: session.asrOutcome,
                refinerBackend: session.refinerBackend,
                refinementOutcome: session.refinementOutcome,
                validationFailureKind: session.validationFailureKind
            )
        } catch {
            if isCurrent(token) {
                appState.lastError = "Could not mark failed polish: \(error.localizedDescription)"
            }
        }
    }

    private func updateHistoryDelivery(
        token: DictationSessionToken,
        status: HistoryDeliveryStatus,
        deliveredText: String,
        error: String? = nil
    ) async {
        guard let historyStore,
              let session = activeSession,
              session.token == token,
              let id = session.historyID
        else { return }
        let stopToPasteLatency = status == .pasteEventSent
            ? session.stoppedAt.map { Date().timeIntervalSince($0) }
            : nil
        do {
            _ = try await historyStore.updateDelivery(
                id: id,
                with: HistoryDeliveryUpdate(
                    status: status,
                    deliveredText: deliveredText,
                    totalLatency: Date().timeIntervalSince(session.startedAt),
                    error: error,
                    asrSelection: session.asrSelection.rawValue,
                    asrOutcome: session.asrOutcome,
                    refinerBackend: session.refinerBackend,
                    refinementOutcome: session.refinementOutcome,
                    validationFailureKind: session.validationFailureKind,
                    stopToPasteLatency: stopToPasteLatency
                )
            )
        } catch {
            if isCurrent(token) {
                appState.lastError = "Could not finalize history: \(error.localizedDescription)"
            }
        }
    }

    private func repasteHistoryText(_ text: String) {
        enqueuePasteAgain(
            text,
            destination: historyRepasteDestination,
            reactivateDestination: true
        )
    }

    private func enqueuePasteAgain(
        _ text: String,
        destination: DictationDestination?,
        reactivateDestination: Bool
    ) {
        pasteAgainQueue.enqueue { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let insertionText = self.safeAutomaticInsertionText(
                text,
                destination: destination
            )
            let outcome = await self.textInserter.insertText(
                insertionText,
                destination: destination,
                reactivateDestination: reactivateDestination
            )
            switch outcome {
            case .pasteEventSent:
                self.appState.lastError = nil
            case .clipboardOnly(let reason), .historyOnly(let reason):
                self.appState.lastError = reason
            case .cancelled:
                break
            }
        }
    }

    private func promptForVocabularyCorrection(from entry: HistoryEntry) {
        let spokenField = NSTextField(string: "")
        spokenField.placeholderString = "What Local Dictation heard"
        let writtenField = NSTextField(string: "")
        writtenField.placeholderString = "What it should write"

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Spoken form"),
            spokenField,
            NSTextField(labelWithString: "Written form"),
            writtenField,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setFrameSize(NSSize(width: 390, height: 108))
        spokenField.widthAnchor.constraint(equalToConstant: 390).isActive = true
        writtenField.widthAnchor.constraint(equalToConstant: 390).isActive = true

        let alert = NSAlert()
        alert.messageText = "Add a personal vocabulary correction?"
        alert.informativeText = "Nothing is learned automatically. Enter one exact phrase mapping, then confirm it. History context: \(Self.historyCorrectionPreview(entry.rawText))"
        alert.accessoryView = stack
        alert.addButton(withTitle: "Add Correction")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let result = try PersonalVocabularyEditor(
                paths: configurationStore.paths
            ).addCorrection(
                spokenForm: spokenField.stringValue,
                writtenForm: writtenField.stringValue
            )
            loadConfiguration(bootstrap: false)
            let confirmation = NSAlert()
            confirmation.messageText = result.replacedExisting
                ? "Personal correction updated"
                : "Personal correction added"
            confirmation.informativeText = "\(result.spokenForm) → \(result.writtenForm)"
            confirmation.alertStyle = .informational
            confirmation.runModal()
        } catch {
            let failure = NSAlert()
            failure.messageText = "Vocabulary correction was not saved"
            failure.informativeText = error.localizedDescription
            failure.alertStyle = .warning
            failure.runModal()
        }
    }

    private static func historyCorrectionPreview(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 120 ? "\(collapsed.prefix(117))…" : collapsed
    }

    private func initializeEngine(onCompletion: ((Bool) -> Void)? = nil) {
        guard activeSession == nil else {
            engineReloadPending = true
            onCompletion?(true)
            return
        }
        engineReloadPending = false
        engineTask?.cancel()
        engineCoordinator.cancelPreparation(selection: appState.asrSelection)
        streamingTranscriber = nil
        transcriptionEngine = nil
        appState.engineReady = false
        appState.isInitializingEngine = true
        let selection = appState.asrSelection
        engineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await self.engineCoordinator.prepare(selection: selection)
                try Task.checkCancellation()
                guard self.appState.asrSelection == selection else { return }
                self.transcriptionEngine = prepared.engine
                // One delayed FluidAudio EOU path serves every authoritative
                // engine and never participates in onboarding readiness.
                self.streamingTranscriber = FluidAudioParakeetStreamingTranscriber()
                self.appState.engineReady = true
                self.appState.lastError = nil
            } catch is CancellationError {
                return
            } catch EngineCoordinatorError.stalePreparation {
                return
            } catch {
                guard self.appState.asrSelection == selection else { return }
                self.transcriptionEngine = nil
                self.streamingTranscriber = nil
                self.appState.engineReady = false
                self.appState.lastError = error.localizedDescription
            }
            self.appState.isInitializingEngine = false
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
        if !textInserter.copyOnly(appState.lastTranscription) {
            appState.lastError = "Could not copy the last dictation to the clipboard"
        }
    }

    @objc private func pasteLast() {
        guard !appState.lastTranscription.isEmpty else { return }
        enqueuePasteAgain(
            appState.lastTranscription,
            destination: DictationDestination.captureFrontmost(),
            reactivateDestination: false
        )
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
            },
            onVerifyModel: { [weak self] in self?.verifySelectedModel() },
            onRepairModel: { [weak self] in self?.confirmRepairSelectedModel() }
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

    private func verifySelectedModel() {
        guard activeSession == nil else {
            appState.lastError = "Finish the current dictation before verifying its speech model."
            return
        }
        let selection = appState.asrSelection
        engineTask?.cancel()
        appState.engineReady = false
        engineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await self.engineCoordinator.verify(selection: selection)
                guard self.appState.asrSelection == selection else { return }
                self.transcriptionEngine = prepared.engine
                self.streamingTranscriber = FluidAudioParakeetStreamingTranscriber()
                self.appState.engineReady = true
                self.appState.lastError = nil
            } catch {
                guard self.appState.asrSelection == selection else { return }
                self.transcriptionEngine = nil
                self.streamingTranscriber = nil
                self.appState.engineReady = false
                self.appState.lastError = "Model verification failed: \(error.localizedDescription)"
            }
        }
    }

    private func confirmRepairSelectedModel() {
        guard activeSession == nil else {
            appState.lastError = "Finish the current dictation before repairing its speech model."
            return
        }
        let selection = appState.asrSelection
        let alert = NSAlert()
        alert.messageText = "Repair \(selection.displayName)?"
        alert.informativeText = "Local Dictation will quarantine only its owned copy of this model, then download and validate a fresh copy from \(selection.sourceHost). Other apps' models are never touched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Repair")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        engineTask?.cancel()
        transcriptionEngine = nil
        streamingTranscriber = nil
        appState.engineReady = false
        engineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await self.engineCoordinator.repair(selection: selection)
                guard self.appState.asrSelection == selection else { return }
                self.transcriptionEngine = prepared.engine
                self.streamingTranscriber = FluidAudioParakeetStreamingTranscriber()
                self.appState.engineReady = true
                self.appState.lastError = nil
            } catch {
                guard self.appState.asrSelection == selection else { return }
                self.appState.lastError = "Model repair failed: \(error.localizedDescription)"
            }
        }
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
        engineMenuItem?.title = "Engine: \(appState.asrSelection.displayName)"
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
