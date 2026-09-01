import Foundation

private actor HistoryDiagnosticsReader {
    static let shared = HistoryDiagnosticsReader()

    func readDefaultHealth(policy: HistoryRetentionPolicy) throws -> HistoryStoreHealth {
        let databaseURL = try HistoryStore.defaultDatabaseURL()
        return try HistoryStore.readOnlyHealth(databaseURL: databaseURL, policy: policy)
    }
}

@MainActor
extension AppState {
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

    func recordTapDiagnostic(
        disableCount: Int,
        rebuildCount: Int,
        lastReason: String?
    ) {
        mutateDiagnosticRuntime {
            $0.tapDisableCount = max(0, disableCount)
            $0.tapRebuildCount = max(0, rebuildCount)
            $0.tapLastReason = TapDiagnosticReason(lastReason)
        }
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
