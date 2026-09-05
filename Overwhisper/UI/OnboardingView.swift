import AVFoundation
import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    let onRefreshPermissions: () -> Void
    let onRequestMicrophone: () -> Void
    let onRequestInputMonitoring: () -> Void
    let onRequestAccessibility: () -> Void
    let onPrepareAndFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Local Dictation")
                    .font(.largeTitle.bold())
                Text("Fast local speech-to-text anywhere on your Mac")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    permissionRow(
                        title: "Microphone",
                        detail: "Records a temporary 16 kHz mono WAV for local ASR.",
                        granted: appState.microphonePermissionGranted,
                        action: onRequestMicrophone
                    )
                    Divider()
                    permissionRow(
                        title: "Input Monitoring",
                        detail: "Recognizes Hyper+D and safely owns Enter/Escape during a session.",
                        granted: appState.inputMonitoringGranted,
                        action: onRequestInputMonitoring
                    )
                    Divider()
                    permissionRow(
                        title: "Accessibility",
                        detail: "Pastes with Command+V without taking focus from your destination.",
                        granted: appState.accessibilityGranted,
                        action: onRequestAccessibility
                    )
                    Divider()
                    statusRow(
                        title: "Hyper+D listener",
                        detail: "The event tap is running and receiving global shortcut events.",
                        ready: appState.hotkeyMonitoringActive
                    )
                    Divider()
                    statusRow(
                        title: "Selected speech model",
                        detail: "The chosen local engine has loaded and passed preparation.",
                        ready: appState.engineReady
                    )
                }
                .padding(4)
            }

            Label("Audio always stays local", systemImage: "lock.shield.fill")
                .foregroundStyle(.green)
            Text("Finishing setup downloads the selected speech model directly to this Mac. No model is downloaded until you choose the button below; transcription then runs locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("First-time ASR and optional live-preview model downloads contact huggingface.co. Microphone audio and transcripts remain on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if appState.isInitializingEngine || appState.isDownloadingModel {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.diagnosticRuntimeState.modelPhase.userFacingTitle)
                            .fontWeight(.semibold)
                        if let model = appState.currentlyDownloadingModel, !model.isEmpty {
                            Text(model)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let detail = appState.diagnosticRuntimeState.modelPhase.userFacingDetail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let error = appState.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Text("Shortcut: Hyper+D")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Spacer()
                Button(appState.onboardingReady ? "Finish Setup" : "Prepare & Finish Setup") {
                    onPrepareAndFinish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !basePermissionsReady
                        || appState.isInitializingEngine
                        || appState.isDownloadingModel
                )
            }
        }
        .padding(28)
        .frame(width: 620, height: 590)
        .onAppear(perform: onRefreshPermissions)
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Allow", action: action) }
        }
    }

    private var basePermissionsReady: Bool {
        appState.basePermissionsReady
    }

    @ViewBuilder
    private func statusRow(
        title: String,
        detail: String,
        ready: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                .foregroundStyle(ready ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ready ? "Ready" : "Not ready")
                .font(.caption)
                .foregroundStyle(ready ? Color.green : Color.orange)
        }
    }
}
