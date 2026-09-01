import AppKit
import Combine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var audioDeviceManager: AudioDeviceManager
    let configurationDirectory: URL
    let onReloadConfiguration: () -> Void
    let onOpenHistory: () -> Void
    let onRefreshPermissions: () -> Void
    let onRetryHotkey: () -> Void
    let onRequestMicrophone: () -> Void
    let onOpenMicrophone: () -> Void
    let onOpenInputMonitoring: () -> Void
    let onOpenAccessibility: () -> Void
    let onImportRaycastVocabulary: (String) -> Void
    let onVerifyModel: () -> Void
    let onRepairModel: () -> Void

    private let permissionRefreshTimer = Timer.publish(
        every: 1,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gear") }
            speech
                .tabItem { Label("Speech", systemImage: "waveform") }
            privacy
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            DiagnosticsSettingsView(appState: appState)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 610, height: 540)
        .padding(18)
        .onAppear(perform: onRefreshPermissions)
        .onReceive(permissionRefreshTimer) { _ in onRefreshPermissions() }
    }

    private var general: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Record") {
                    Text("Hyper+D")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                }
                Text("Tap to toggle. Hold longer than 350 ms for push-to-talk. Enter finishes unless typing was detected; Escape always cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions & hotkey health") {
                permissionRow("Microphone", granted: appState.microphonePermissionGranted)
                permissionRow("Input Monitoring", granted: appState.inputMonitoringGranted)
                permissionRow("Accessibility", granted: appState.accessibilityGranted)
                permissionRow("Hyper+D listener", granted: appState.hotkeyMonitoringActive)

                if let error = appState.hotkeyMonitoringError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                HStack {
                    Button(
                        appState.microphonePermissionGranted ? "Microphone…" : "Request Microphone",
                        action: appState.microphonePermissionGranted
                            ? onOpenMicrophone
                            : onRequestMicrophone
                    )
                    Button("Input Monitoring…", action: onOpenInputMonitoring)
                    Button("Accessibility…", action: onOpenAccessibility)
                    Button("Refresh", action: onRefreshPermissions)
                    Spacer()
                    Button("Retry Hyper+D", action: onRetryHotkey)
                        .buttonStyle(.borderedProminent)
                }

                Text("Source builds use a stable per-machine signing identity. Permission state refreshes while this window is open; an identity rotation is the only rebuild that should require a new one-time permission reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Overlay") {
                Picker("Position", selection: $appState.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section("Configuration") {
                LabeledContent("Directory") {
                    Text(configurationDirectory.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([configurationDirectory]) }
                    Button("Reload", action: onReloadConfiguration)
                    Spacer()
                    Button("History…", action: onOpenHistory)
                }
                if let diagnostic = appState.configurationDiagnostic {
                    Label(diagnostic, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                ForEach(appState.configurationNotices, id: \.self) { notice in
                    Label(notice, systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            Section("Raycast vocabulary import") {
                TextEditor(text: $appState.raycastVocabularyImportText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 58)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 1)
                    }
                HStack {
                    Text("Paste Raycast's comma-separated vocabulary. Local Dictation never reads Raycast data directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Import") {
                        onImportRaycastVocabulary(appState.raycastVocabularyImportText)
                    }
                    .disabled(appState.raycastVocabularyImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(_ title: String, granted: Bool) -> some View {
        HStack {
            Label(
                title,
                systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            Spacer()
            Text(granted ? "Ready" : "Needs attention")
                .foregroundStyle(granted ? Color.green : Color.orange)
        }
    }

    private var speech: some View {
        Form {
            Section("Local transcription") {
                Picker("Engine", selection: $appState.asrSelection) {
                    ForEach(ASRSelection.allCases) { selection in
                        Text(selection.displayName).tag(selection)
                    }
                }

                LabeledContent("Status") {
                    if appState.engineReady {
                        Text("Ready").foregroundStyle(.green)
                    } else if appState.isInitializingEngine || appState.isDownloadingModel {
                        Text("Preparing…").foregroundStyle(.orange)
                    } else {
                        Text("Unavailable").foregroundStyle(.red)
                    }
                }

                if appState.isDownloadingModel {
                    ProgressView(value: appState.modelDownloadProgress)
                }

                HStack {
                    Button("Verify", action: onVerifyModel)
                        .disabled(appState.isInitializingEngine || appState.isDownloadingModel)
                    Button("Repair…", role: .destructive, action: onRepairModel)
                        .disabled(appState.isInitializingEngine || appState.isDownloadingModel)
                    Spacer()
                    Text(appState.asrSelection.estimatedSize)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Parakeet v2 is the daily-driver default until the checked-in corpus mechanically selects a winner. English is the only enabled v1 language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("First-time ASR and optional FluidAudio EOU live-preview downloads contact \(appState.asrSelection.sourceHost). Audio and transcripts remain on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Input", selection: $appState.selectedInputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(audioDeviceManager.inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            Section("Invariant") {
                Label("Microphone audio never leaves this Mac", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("There is no telemetry SDK, cloud speech engine, automatic updater, or Overseed service in this build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Network access is limited to first-time model downloads from the documented model host and any text-only refiner you explicitly configure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Advanced cleanup") {
                Toggle(
                    "Experimental model cleanup",
                    isOn: $appState.experimentalModelCleanupEnabled
                )
                Text("Off by default. Deterministic local cleanup remains active when this experiment is disabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.experimentalModelCleanupEnabled {
                    SecureField(
                        "OpenAI-compatible API key (optional)",
                        text: $appState.refinerAPIKey
                    )
                    .textContentType(.password)
                    Text("A configured model receives transcript text, static cleanup rules, and transcript-derived allowed-deletion ranges only. It never receives audio, app identity, browser data, field contents, or surrounding text. Non-loopback hosts require explicit remote opt-in and display a persistent Remote badge.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Audio retention") {
                Toggle("Keep the latest 10 debug recordings", isOn: $appState.retainDebugAudio)
                Text("Off by default. Temporary WAV files are removed after transcription or cancellation and crash orphans are cleaned on launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DebugRetentionControls(store: appState.debugSessionStore)
            }

            Section("Clipboard") {
                Toggle("Private Clipboard Mode", isOn: $appState.privateClipboardMode)
                Text("Off by default so clipboard managers can retain dictations. When enabled, Local Dictation adds best-effort concealed and transient pasteboard markers; the transcript still remains on the clipboard after an insertion attempt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DebugRetentionControls: View {
    @ObservedObject var store: DebugSessionStore

    var body: some View {
        HStack {
            Text("Retained: \(store.sessions.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Delete Retained Audio", role: .destructive) {
                store.clear()
            }
            .disabled(store.sessions.isEmpty)
        }
    }
}
