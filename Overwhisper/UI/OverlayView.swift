import SwiftUI

enum OverlayMetrics {
    static let width: CGFloat = 390
    static let height: CGFloat = 154
}

struct OverlayView: View {
    @ObservedObject var appState: AppState
    let onCancel: () -> Void
    @State private var smoothedLevel: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
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

            if appState.phase == .recording {
                Waveform(level: smoothedLevel)
                    .frame(height: 32)
            } else if appState.phase != .failed {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 32)
            }

            if !appState.liveTranscript.displayed.isEmpty {
                Text(appState.liveTranscript.displayed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if appState.phase.hasActiveSession {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel and discard this session")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(width: OverlayMetrics.width, height: OverlayMetrics.height)
        .background(OverlaySurface(level: smoothedLevel))
        .onChange(of: appState.audioLevel) { _, value in
            let target = CGFloat(sqrt(Double(max(0, min(1, value)))))
            withAnimation(.easeOut(duration: target > smoothedLevel ? 0.06 : 0.24)) {
                smoothedLevel = max(target, smoothedLevel * 0.78)
            }
        }
        .onChange(of: appState.phase) { _, phase in
            if phase != .recording {
                withAnimation(.easeOut(duration: 0.4)) { smoothedLevel = 0 }
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
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
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
            case .ok: return appState.activeProfileName
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
        case .failed: return "Text remains in history when available"
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
            let width = max(2, (proxy.size.width - CGFloat(count - 1) * 3) / CGFloat(count))
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    let wave = 0.3 + 0.7 * abs(sin(Double(index) * 0.78 + Date().timeIntervalSinceReferenceDate * 2.4))
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
    let level: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .black.opacity(0.38),
                                .indigo.opacity(0.12 + level * 0.12),
                                .black.opacity(0.42),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.18 + level * 0.15), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
            .padding(6)
    }
}
