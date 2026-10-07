import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    let onCancel: () -> Void
    let onFinish: () -> Void
    let onPreview: () -> Void
    let onSettings: () -> Void
    let onDragEnd: () -> Void
    let onPosition: (OverlayPosition) -> Void
    @State private var smoothedLevel: CGFloat = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                phaseIcon
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(appState.overlayMessage)
                            .font(.system(size: 14, weight: .semibold))
                        if appState.isRemoteRefiner {
                            Text("REMOTE")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.22), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(secondaryMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if appState.phase == .recording {
                    Text(Self.duration(appState.recordingDuration))
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay { OverlayDragRegion(onDragEnd: onDragEnd).help("Drag to move the dictation overlay") }

            if !appState.overlayCompact, appState.phase == .recording {
                Waveform(level: smoothedLevel)
                    .frame(height: 32)
            } else if !appState.overlayCompact, appState.phase != .failed {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 32)
            }

            if !appState.overlayCompact, !appState.liveTranscript.displayed.isEmpty {
                Text(appState.liveTranscript.displayed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Finish", systemImage: "stop.fill", action: onFinish)
                    .disabled(appState.phase != .recording)
                    .help("Finish dictation and paste into the captured destination")
                Button("Preview", systemImage: "text.page", action: onPreview)
                    .disabled(appState.phase != .recording)
                    .help("Finish into editable preview")
                Spacer()
                Button {
                    appState.overlayQuickControlsVisible.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Overlay appearance")
                if appState.phase.hasActiveSession {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel and discard this session")
                }
            }
            .buttonStyle(.plain)
            .font(.caption)

            if appState.overlayQuickControlsVisible {
                VStack(spacing: 8) {
                    HStack {
                        Text("Background").font(.caption)
                        Slider(value: $appState.overlayBackgroundStrength, in: OverlayAppearance.strengthRange)
                            .disabled(reduceTransparency)
                            .help("Background strength; text and controls stay fully visible")
                        Text(reduceTransparency ? "Opaque" : "\(Int(appState.overlayBackgroundStrength * 100))%")
                            .font(.caption.monospacedDigit()).frame(width: 44)
                    }
                    HStack {
                        Toggle("Compact", isOn: $appState.overlayCompact).toggleStyle(.switch)
                        Spacer()
                        Button("Top") { onPosition(.topCenter) }
                        Button("Bottom") { onPosition(.bottomCenter) }
                    }.font(.caption)
                    HStack {
                        Text(appState.phase == .recording ? hint : "Drag the header to move this box")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Settings…", action: onSettings)
                            .disabled(appState.phase != .idle && appState.phase != .failed)
                            .help("Full settings are available after dictation finishes")
                    }.font(.caption)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(width: 390, height: OverlayAppearance.size(compact: appState.overlayCompact,
            controls: appState.overlayQuickControlsVisible).height)
        .background(OverlaySurface(strength: appState.overlayBackgroundStrength, reduceTransparency: reduceTransparency))
        .onChange(of: appState.audioLevel) { _, value in
            let target = CGFloat(sqrt(Double(max(0, min(1, value)))))
            withAnimation(reduceMotion ? nil : .easeOut(duration: target > smoothedLevel ? 0.06 : 0.24)) {
                smoothedLevel = max(target, smoothedLevel * 0.78)
            }
        }
        .onChange(of: appState.phase) { _, phase in
            if phase != .recording {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { smoothedLevel = 0 }
            }
        }
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch appState.phase {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .shadow(color: .red.opacity(0.6), radius: 5)
        case .failed:
            Image(systemName: appState.lastDictationFailure?.isNeutral == true
                ? "info.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(appState.lastDictationFailure?.isNeutral == true ? Color.secondary : Color.orange)
        case .idle:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        default:
            Image(systemName: "waveform.badge.magnifyingglass")
                .foregroundStyle(.indigo)
        }
    }

    private var secondaryMessage: String {
        if appState.phase == .recording {
            switch appState.micInputStatus {
            case .ok: return appState.microphoneNotice ?? appState.activeProfileName
            case .low: return "Microphone level is low"
            case .silent: return "No usable microphone input detected"
            }
        }
        return appState.lastError ?? appState.activeProfileName
    }

    private var hint: String {
        if appState.interleavedTyping { return "Enter belongs to the current app · Hyper+D to finish" }
        switch appState.phase {
        case .recording: return "Enter finish · ⌥ literal · ⇧ preview · esc cancel"
        case .failed: return appState.lastDictationFailure?.recoveryAction ?? "Text remains in history when available"
        default: return "esc cancel"
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct Waveform: View {
    let level: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let count = 32
            let time = Date().timeIntervalSinceReferenceDate
            let width = max(2, (proxy.size.width - CGFloat(count - 1) * 3) / CGFloat(count))
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    let wave = 0.3 + 0.7 * abs(sin(Double(index) * 0.78 + time * 2.4))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.indigo.opacity(0.7), .cyan.opacity(0.9)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: width, height: max(3, proxy.size.height * (0.10 + level * CGFloat(wave))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .drawingGroup()
    }
}

private struct OverlaySurface: View {
    let strength: Double
    let reduceTransparency: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.ultraThinMaterial))
            .opacity(reduceTransparency ? 1 : strength)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .black.opacity(reduceTransparency ? 0 : 0.18 * strength),
                                .indigo.opacity(reduceTransparency ? 0 : 0.10 * strength),
                                .black.opacity(reduceTransparency ? 0 : 0.22 * strength),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            .padding(6)
    }
}
