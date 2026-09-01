import AppKit
import SwiftUI

struct DiagnosticsSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var copied = false

    private var snapshot: PrivacySafeDiagnosticSnapshot {
        PrivacySafeDiagnosticSnapshot(appState: appState)
    }

    var body: some View {
        Form {
            Section("Permissions") {
                diagnosticRow("Microphone", state: snapshot.permissions.microphone)
                diagnosticRow("Input Monitoring", state: snapshot.permissions.inputMonitoring)
                diagnosticRow("Accessibility", state: snapshot.permissions.accessibility)
            }

            Section("Runtime") {
                diagnosticRow("Hyper+D event tap", state: snapshot.tap.state)
                valueRow("Tap disables", value: String(snapshot.tap.disableCount))
                valueRow("Tap rebuilds", value: String(snapshot.tap.rebuildCount))
                valueRow("Last tap reason", value: snapshot.tap.lastReason.displayName)
                diagnosticRow(
                    "Authoritative model",
                    state: snapshot.model.state,
                    detail: snapshot.model.selection.displayName
                )
                valueRow("Model phase", value: snapshot.model.phase.rawValue)
                valueRow(
                    "Owned model path",
                    value: snapshot.model.ownedPath ?? "Not available"
                )
                valueRow("Last model failure", value: snapshot.model.lastFailure.displayName)
                diagnosticRow(
                    "EOU live preview",
                    state: snapshot.eou.health,
                    detail: snapshot.eou.state.displayName
                )
                diagnosticRow(
                    "Configuration",
                    state: snapshot.configuration.state,
                    detail: "\(snapshot.configuration.noticeCount) notice(s)"
                )
                valueRow(
                    "Configuration generation",
                    value: String(snapshot.configuration.generation)
                )
                valueRow(
                    "Last-known-good active",
                    value: snapshot.configuration.usingLastKnownGood ? "Yes" : "No"
                )
            }

            Section("History") {
                diagnosticRow("Store", state: snapshot.history.state)
                valueRow("Journal", value: snapshot.history.journalMode.displayName)
                valueRow(
                    "Migrations",
                    value: snapshot.history.migrationCount.map {
                        "\($0)/\(HistoryStore.expectedMigrationIdentifiers.count)"
                    } ?? "Not available"
                )
                valueRow(
                    "Entries",
                    value: snapshot.history.entryCount.map(String.init) ?? "Not available"
                )
                valueRow(
                    "Pending entries",
                    value: snapshot.history.pendingEntryCount.map(String.init) ?? "Not available"
                )
                valueRow(
                    "Retention",
                    value: snapshot.history.retentionDays.map { "\($0) days" } ?? "Not available"
                )
                valueRow("Integrity", value: snapshot.history.integrityCheck.displayName)
            }

            Section("Insertion") {
                diagnosticRow(
                    "Last outcome",
                    state: snapshot.insertion.state,
                    detail: snapshot.insertion.lastOutcome.displayName
                )
                valueRow(
                    "Failure reason",
                    value: snapshot.insertion.lastFailure.displayName
                )
            }

            Section("Privacy-safe report") {
                Text("This report contains only allowlisted operational states and counts. It never includes transcript text, clipboard contents, audio, browser data, URLs or hostnames, API keys, destination identity, or focused-field content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Refresh") {
                        Task { await appState.refreshPrivacySafeDiagnostics() }
                    }
                    Spacer()
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Button("Copy Diagnostics") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        copied = pasteboard.setString(
                            snapshot.renderedReport,
                            forType: .string
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await appState.refreshPrivacySafeDiagnostics() }
    }

    private func diagnosticRow(
        _ title: String,
        state: DiagnosticHealthState,
        detail: String? = nil
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Label(state.displayName, systemImage: state.symbolName)
                .foregroundStyle(state.color)
        }
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private extension DiagnosticHealthState {
    var displayName: String {
        switch self {
        case .ready: "Ready"
        case .preparing: "Preparing"
        case .degraded: "Degraded"
        case .needsAttention: "Needs attention"
        case .unavailable: "Unavailable"
        case .inactive: "Inactive"
        case .unknown: "Not observed"
        }
    }

    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .preparing: "clock.fill"
        case .degraded: "exclamationmark.circle.fill"
        case .needsAttention, .unavailable: "xmark.circle.fill"
        case .inactive, .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .preparing, .degraded, .needsAttention: .orange
        case .unavailable: .red
        case .inactive, .unknown: .secondary
        }
    }
}

private extension EOUDiagnosticState {
    var displayName: String {
        switch self {
        case .notObserved: "Not observed"
        case .preparing: "Preparing"
        case .configured: "Configured"
        case .streaming: "Streaming"
        case .degraded: "Degraded"
        case .unavailable: "Unavailable"
        }
    }
}

private extension TapDiagnosticReason {
    var displayName: String {
        switch self {
        case .none: "None"
        case .systemTimeout: "System timeout"
        case .userInput: "Disabled by user input"
        case .reenableFailed: "Re-enable failed"
        case .healthRebuild: "Health-check rebuild"
        case .other: "Other operational reason"
        }
    }
}

private extension ModelDiagnosticFailureKind {
    var displayName: String {
        switch self {
        case .none: "None"
        case .download: "Download failed"
        case .validation: "Validation failed"
        case .repair: "Repair failed"
        case .initialization: "Initialization failed"
        }
    }
}

private extension InsertionDiagnosticFailureKind {
    var displayName: String {
        switch self {
        case .none: "None"
        case .secureDestination: "Secure destination"
        case .clipboardWrite: "Clipboard write failed"
        case .accessibility: "Accessibility unavailable"
        case .destinationMissing: "No captured destination"
        case .destinationChanged: "Destination changed"
        case .clipboardChanged: "Clipboard changed"
        case .pasteEvent: "Paste event unavailable"
        case .cancelled: "Cancelled"
        case .other: "Other operational failure"
        }
    }
}

private extension HistoryJournalDiagnosticState {
    var displayName: String {
        switch self {
        case .wal: "WAL"
        case .other: "Unexpected mode"
        case .notAvailable: "Not available"
        }
    }
}

private extension HistoryIntegrityDiagnosticState {
    var displayName: String {
        switch self {
        case .passed: "Passed"
        case .failed: "Failed"
        case .notObserved: "Not observed"
        }
    }
}

private extension InsertionDiagnosticOutcome {
    var displayName: String {
        switch self {
        case .notObserved: "Not observed"
        case .pending: "Pending"
        case .delivered: "Delivered (legacy)"
        case .previewed: "Previewed"
        case .pastedRaw: "Pasted raw (legacy)"
        case .pasteEventSent: "Paste event sent"
        case .clipboardOnly: "Clipboard only"
        case .historyOnly: "History only"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
