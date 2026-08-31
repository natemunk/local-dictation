import AVFoundation
import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    let onComplete: () -> Void
    @State private var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var inputMonitoringGranted = CGPreflightListenEventAccess()

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
                        granted: microphoneGranted,
                        action: requestMicrophone
                    )
                    Divider()
                    permissionRow(
                        title: "Input Monitoring",
                        detail: "Recognizes Hyper+D and safely owns Enter/Escape during a session.",
                        granted: inputMonitoringGranted,
                        action: requestInputMonitoring
                    )
                    Divider()
                    permissionRow(
                        title: "Accessibility",
                        detail: "Pastes with Command+V without taking focus from your destination.",
                        granted: accessibilityGranted,
                        action: requestAccessibility
                    )
                }
                .padding(4)
            }

            Label("Audio always stays local", systemImage: "lock.shield.fill")
                .foregroundStyle(.green)
            Text("Finishing setup downloads the selected speech model directly to this Mac. No model is downloaded until you choose the button below; transcription then runs locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Browser Automation is optional and is requested later only if you enable hostname profiles. It is not needed for first dictation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if appState.isInitializingEngine || appState.isDownloadingModel {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preparing the local speech model…")
                            .fontWeight(.semibold)
                        if let model = appState.currentlyDownloadingModel, !model.isEmpty {
                            Text(model)
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
                Button("Finish Setup & Download Local Model") {
                    appState.hasCompletedOnboarding = true
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!microphoneGranted || appState.isInitializingEngine || appState.isDownloadingModel)
            }
        }
        .padding(28)
        .frame(width: 600, height: 500)
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

    private func requestMicrophone() {
        Task {
            microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    private func requestInputMonitoring() {
        inputMonitoringGranted = CGRequestListenEventAccess()
        if !inputMonitoringGranted {
            openPrivacyPane("Privacy_ListenEvent")
        }
    }

    private func requestAccessibility() {
        accessibilityGranted = TextInserter.requestAccessibilityPermission()
        if !accessibilityGranted {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
