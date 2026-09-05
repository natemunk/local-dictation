import Foundation

struct PermissionDiagnosticReading: Equatable, Sendable {
    let microphoneGranted: Bool
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool
    let hotkeyMonitoringActive: Bool
    let tapDisableCount: Int
    let tapRebuildCount: Int
    let tapLastReason: String?
}

private actor HistoryDiagnosticsReader {
    static let shared = HistoryDiagnosticsReader()

    func readDefaultHealth(policy: HistoryRetentionPolicy) throws -> HistoryStoreHealth {
        let databaseURL = try HistoryStore.defaultDatabaseURL()
        return try HistoryStore.readOnlyHealth(databaseURL: databaseURL, policy: policy)
    }
}

@MainActor
extension AppState {
    /// Applies one permission/tap sample without publishing values that have
    /// not changed. This keeps activation and Settings refreshes effectively
    /// free when the system state is stable.
    @discardableResult
    func applyPermissionDiagnostics(_ reading: PermissionDiagnosticReading) -> Bool {
        var changed = false

        if microphonePermissionGranted != reading.microphoneGranted {
            microphonePermissionGranted = reading.microphoneGranted
            changed = true
        }
        if inputMonitoringGranted != reading.inputMonitoringGranted {
            inputMonitoringGranted = reading.inputMonitoringGranted
            changed = true
        }
        if accessibilityGranted != reading.accessibilityGranted {
            accessibilityGranted = reading.accessibilityGranted
            changed = true
        }
        if hotkeyMonitoringActive != reading.hotkeyMonitoringActive {
            hotkeyMonitoringActive = reading.hotkeyMonitoringActive
            changed = true
        }
        if recordTapDiagnostic(
            disableCount: reading.tapDisableCount,
            rebuildCount: reading.tapRebuildCount,
            lastReason: reading.tapLastReason
        ) {
            changed = true
        }

        return changed
    }

    /// Refreshes only schema/runtime metadata from history. The read-only path
    /// never fetches transcript, destination, error, or search-index content.
    func refreshPrivacySafeDiagnostics() async {
        mutateDiagnosticRuntime { $0.history = .loading }
        do {
            let policy = HistoryRetentionPolicy(
                retentionDays: diagnosticRuntimeState.historyRetentionDays
            )
            let health = try await HistoryDiagnosticsReader.shared.readDefaultHealth(
                policy: policy
            )
            guard !Task.isCancelled else { return }
            updateHistoryDiagnosticHealth(health)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            mutateDiagnosticRuntime { $0.history = .unavailable }
        }
    }

    func updateHistoryDiagnosticHealth(_ health: HistoryStoreHealth) {
        mutateDiagnosticRuntime { runtime in
            runtime.history = .available(health)
            if runtime.insertion == .notObserved {
                runtime.insertion = InsertionDiagnosticOutcome(health.lastDeliveryStatus)
            }
        }
    }

    @discardableResult
    func recordTapDiagnostic(
        disableCount: Int,
        rebuildCount: Int,
        lastReason: String?
    ) -> Bool {
        let disableCount = max(0, disableCount)
        let rebuildCount = max(0, rebuildCount)
        let reason = TapDiagnosticReason(lastReason)
        guard diagnosticRuntimeState.tapDisableCount != disableCount
                || diagnosticRuntimeState.tapRebuildCount != rebuildCount
                || diagnosticRuntimeState.tapLastReason != reason
        else { return false }

        mutateDiagnosticRuntime {
            $0.tapDisableCount = disableCount
            $0.tapRebuildCount = rebuildCount
            $0.tapLastReason = reason
        }
        return true
    }

    func recordModelDiagnostic(_ status: EngineStatus) {
        mutateDiagnosticRuntime {
            $0.modelPhase = status.phase
            $0.modelPreparationGeneration = status.preparationGeneration
            $0.modelHasOwnedPath = status.ownedPath != nil
            $0.modelLastFailure = ModelDiagnosticFailureKind(status.lastError)
        }
    }

    func recordConfigurationDiagnostic(
        generation: UInt64,
        applied: Bool,
        historyRetentionDays: Int
    ) {
        mutateDiagnosticRuntime {
            $0.configurationGeneration = generation
            $0.configurationUsingLastKnownGood = !applied
            $0.historyRetentionDays = max(1, historyRetentionDays)
        }
    }

    /// Stores only the closed outcome enum. Associated reason text is discarded.
    func recordInsertionDiagnostic(_ outcome: InsertionOutcome) {
        mutateDiagnosticRuntime {
            $0.insertion = InsertionDiagnosticOutcome(outcome)
            $0.insertionFailure = InsertionDiagnosticFailureKind(outcome)
        }
    }

    func recordEOUDiagnostic(_ state: EOUDiagnosticState) {
        mutateDiagnosticRuntime { $0.eou = state }
    }

    private func mutateDiagnosticRuntime(
        _ mutation: (inout DiagnosticRuntimeState) -> Void
    ) {
        var runtime = diagnosticRuntimeState
        mutation(&runtime)
        diagnosticRuntimeState = runtime
    }
}
