import Foundation

enum DiagnosticHealthState: String, Encodable, CaseIterable, Sendable {
    case ready
    case preparing
    case degraded
    case needsAttention = "needs_attention"
    case unavailable
    case inactive
    case unknown
}

enum EOUDiagnosticState: String, Encodable, CaseIterable, Sendable {
    case notObserved = "not_observed"
    case preparing
    case configured
    case streaming
    case degraded
    case unavailable

    var health: DiagnosticHealthState {
        switch self {
        case .configured, .streaming:
            .ready
        case .preparing:
            .preparing
        case .degraded:
            .degraded
        case .unavailable:
            .unavailable
        case .notObserved:
            .unknown
        }
    }
}

enum InsertionDiagnosticOutcome: String, Encodable, CaseIterable, Sendable {
    case notObserved = "not_observed"
    case pending
    case delivered
    case previewed
    case pastedRaw = "pasted_raw"
    case pasteEventSent = "paste_event_sent"
    case clipboardOnly = "clipboard_only"
    case historyOnly = "history_only"
    case failed
    case cancelled

    init(_ outcome: InsertionOutcome) {
        switch outcome {
        case .pasteEventSent:
            self = .pasteEventSent
        case .clipboardOnly:
            self = .clipboardOnly
        case .historyOnly:
            self = .historyOnly
        case .cancelled:
            self = .cancelled
        }
    }

    init(_ status: HistoryDeliveryStatus?) {
        guard let status else {
            self = .notObserved
            return
        }
        switch status {
        case .pending:
            self = .pending
        case .delivered:
            self = .delivered
        case .previewed:
            self = .previewed
        case .pastedRaw:
            self = .pastedRaw
        case .pasteEventSent:
            self = .pasteEventSent
        case .clipboardOnly:
            self = .clipboardOnly
        case .historyOnly:
            self = .historyOnly
        case .failed:
            self = .failed
        case .cancelled:
            self = .cancelled
        }
    }

    var health: DiagnosticHealthState {
        switch self {
        case .delivered, .previewed, .pastedRaw, .pasteEventSent:
            .ready
        case .clipboardOnly:
            .degraded
        case .historyOnly, .failed:
            .needsAttention
        case .pending:
            .preparing
        case .cancelled:
            .inactive
        case .notObserved:
            .unknown
        }
    }
}

enum TapDiagnosticReason: String, Encodable, CaseIterable, Sendable {
    case none
    case systemTimeout = "system_timeout"
    case userInput = "user_input"
    case reenableFailed = "reenable_failed"
    case healthRebuild = "health_rebuild"
    case other

    init(_ reason: String?) {
        guard let reason else {
            self = .none
            return
        }
        if reason.contains("system timeout") {
            self = .systemTimeout
        } else if reason == "user input" {
            self = .userInput
        } else if reason.contains("re-enable failed")
                    || reason.contains("remained disabled") {
            self = .reenableFailed
        } else if reason.contains("health check") {
            self = .healthRebuild
        } else {
            self = .other
        }
    }
}

enum ModelDiagnosticFailureKind: String, Encodable, CaseIterable, Sendable {
    case none
    case download
    case validation
    case repair
    case initialization

    init(_ message: String?) {
        guard let message, !message.isEmpty else {
            self = .none
            return
        }
        let lowered = message.lowercased()
        if lowered.contains("download") {
            self = .download
        } else if lowered.contains("valid")
                    || lowered.contains("manifest")
                    || lowered.contains("missing") {
            self = .validation
        } else if lowered.contains("repair") || lowered.contains("quarantine") {
            self = .repair
        } else {
            self = .initialization
        }
    }
}

enum InsertionDiagnosticFailureKind: String, Encodable, CaseIterable, Sendable {
    case none
    case secureDestination = "secure_destination"
    case clipboardWrite = "clipboard_write"
    case accessibility
    case destinationMissing = "destination_missing"
    case destinationChanged = "destination_changed"
    case clipboardChanged = "clipboard_changed"
    case pasteEvent = "paste_event"
    case cancelled
    case other

    init(_ outcome: InsertionOutcome) {
        switch outcome {
        case .pasteEventSent:
            self = .none
        case .cancelled:
            self = .cancelled
        case .clipboardOnly(let reason), .historyOnly(let reason):
            let lowered = reason.lowercased()
            if lowered.contains("secure field") {
                self = .secureDestination
            } else if lowered.contains("write") && lowered.contains("clipboard") {
                self = .clipboardWrite
            } else if lowered.contains("accessibility") {
                self = .accessibility
            } else if lowered.contains("no focused editable destination") {
                self = .destinationMissing
            } else if lowered.contains("no longer focused") {
                self = .destinationChanged
            } else if lowered.contains("clipboard changed") {
                self = .clipboardChanged
            } else if lowered.contains("paste event") {
                self = .pasteEvent
            } else {
                self = .other
            }
        }
    }
}

enum HistoryJournalDiagnosticState: String, Encodable, Sendable {
    case wal
    case other
    case notAvailable = "not_available"

    init(journalMode: String) {
        self = journalMode.caseInsensitiveCompare("wal") == .orderedSame ? .wal : .other
    }
}

enum HistoryIntegrityDiagnosticState: String, Encodable, Sendable {
    case passed
    case failed
    case notObserved = "not_observed"
}

enum HistoryDiagnosticObservation: Equatable, Sendable {
    case notLoaded
    case loading
    case available(HistoryStoreHealth)
    case unavailable
}

struct DiagnosticRuntimeState: Equatable, Sendable {
    var tapDisableCount = 0
    var tapRebuildCount = 0
    var tapLastReason: TapDiagnosticReason = .none
    var modelPhase: EngineLifecyclePhase = .idle
    var modelPreparationGeneration: UInt64 = 0
    var modelHasOwnedPath = false
    var modelLastFailure: ModelDiagnosticFailureKind = .none
    var eou: EOUDiagnosticState = .notObserved
    var configurationGeneration: UInt64 = 0
    var configurationUsingLastKnownGood = false
    var historyRetentionDays = HistoryRetentionPolicy.default.retentionDays
    var history: HistoryDiagnosticObservation = .notLoaded
    var insertion: InsertionDiagnosticOutcome = .notObserved
    var insertionFailure: InsertionDiagnosticFailureKind = .none
}

struct PermissionDiagnosticSnapshot: Equatable, Encodable, Sendable {
    let microphone: DiagnosticHealthState
    let inputMonitoring: DiagnosticHealthState
    let accessibility: DiagnosticHealthState

    private enum CodingKeys: String, CodingKey {
        case microphone
        case inputMonitoring = "input_monitoring"
        case accessibility
    }
}

struct TapDiagnosticSnapshot: Equatable, Encodable, Sendable {
    let state: DiagnosticHealthState
    let disableCount: Int
    let rebuildCount: Int
    let lastReason: TapDiagnosticReason

    private enum CodingKeys: String, CodingKey {
        case state
        case disableCount = "disable_count"
        case rebuildCount = "rebuild_count"
        case lastReason = "last_reason"
    }
}

struct ModelDiagnosticSnapshot: Equatable, Encodable, Sendable {
    let selection: ASRSelection
    let state: DiagnosticHealthState
    let phase: EngineLifecyclePhase
    let preparationGeneration: UInt64
    let ownedPath: String?
    let lastFailure: ModelDiagnosticFailureKind

    private enum CodingKeys: String, CodingKey {
        case selection
        case state
        case phase
        case preparationGeneration = "preparation_generation"
        case ownedPath = "owned_path"
        case lastFailure = "last_failure"
    }
}

struct EOUDiagnosticSnapshot: Equatable, Encodable, Sendable {
    let state: EOUDiagnosticState

    var health: DiagnosticHealthState { state.health }
}

struct ConfigurationDiagnosticSnapshot: Equatable, Encodable, Sendable {
    let state: DiagnosticHealthState
    let noticeCount: Int
    let generation: UInt64
    let usingLastKnownGood: Bool

    private enum CodingKeys: String, CodingKey {
        case state
        case noticeCount = "notice_count"
        case generation
        case usingLastKnownGood = "using_last_known_good"
    }
}

struct HistoryDiagnosticSnapshot: Equatable, Encodable, Sendable {
    let state: DiagnosticHealthState
    let journalMode: HistoryJournalDiagnosticState
    let migrationCount: Int?
    let entryCount: Int?
    let pendingEntryCount: Int?
    let retentionDays: Int?
    let integrityCheck: HistoryIntegrityDiagnosticState

    private enum CodingKeys: String, CodingKey {
        case state
        case journalMode = "journal_mode"
        case migrationCount = "migration_count"
        case entryCount = "entry_count"
        case pendingEntryCount = "pending_entry_count"
        case retentionDays = "retention_days"
        case integrityCheck = "integrity_check"
    }
}

struct InsertionDiagnosticSnapshot: Equatable, Encodable, Sendable {
    let state: DiagnosticHealthState
    let lastOutcome: InsertionDiagnosticOutcome
    let lastFailure: InsertionDiagnosticFailureKind

    private enum CodingKeys: String, CodingKey {
        case state
        case lastOutcome = "last_outcome"
        case lastFailure = "last_failure"
    }
}

enum DiagnosticFieldName: String, CaseIterable, Sendable {
    case schemaVersion = "schema_version"
    case microphonePermission = "permissions.microphone"
    case inputMonitoringPermission = "permissions.input_monitoring"
    case accessibilityPermission = "permissions.accessibility"
    case tapState = "tap.state"
    case tapDisableCount = "tap.disable_count"
    case tapRebuildCount = "tap.rebuild_count"
    case tapLastReason = "tap.last_reason"
    case modelSelection = "model.selection"
    case modelState = "model.state"
    case modelPhase = "model.phase"
    case modelPreparationGeneration = "model.preparation_generation"
    case modelOwnedPath = "model.owned_path"
    case modelLastFailure = "model.last_failure"
    case eouState = "eou.state"
    case configurationState = "configuration.state"
    case configurationNoticeCount = "configuration.notice_count"
    case configurationGeneration = "configuration.generation"
    case configurationUsingLastKnownGood = "configuration.using_last_known_good"
    case historyState = "history.state"
    case historyJournalMode = "history.journal_mode"
    case historyMigrationCount = "history.migration_count"
    case historyEntryCount = "history.entry_count"
    case historyPendingEntryCount = "history.pending_entry_count"
    case historyRetentionDays = "history.retention_days"
    case historyIntegrityCheck = "history.integrity_check"
    case insertionState = "insertion.state"
    case insertionLastOutcome = "insertion.last_outcome"
    case insertionLastFailure = "insertion.last_failure"
}

struct DiagnosticField: Equatable, Sendable {
    let name: DiagnosticFieldName
    let value: String

    fileprivate init(_ name: DiagnosticFieldName, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// A closed diagnostic payload made only from allowlisted enums, booleans, and
/// counts. Content-bearing state is intentionally absent from its initializer.
struct PrivacySafeDiagnosticSnapshot: Equatable, Encodable, Sendable {
    let schemaVersion: Int
    let permissions: PermissionDiagnosticSnapshot
    let tap: TapDiagnosticSnapshot
    let model: ModelDiagnosticSnapshot
    let eou: EOUDiagnosticSnapshot
    let configuration: ConfigurationDiagnosticSnapshot
    let history: HistoryDiagnosticSnapshot
    let insertion: InsertionDiagnosticSnapshot

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case permissions
        case tap
        case model
        case eou
        case configuration
        case history
        case insertion
    }

    @MainActor
    init(appState: AppState) {
        schemaVersion = 1
        permissions = PermissionDiagnosticSnapshot(
            microphone: appState.microphonePermissionGranted ? .ready : .needsAttention,
            inputMonitoring: appState.inputMonitoringGranted ? .ready : .needsAttention,
            accessibility: appState.accessibilityGranted ? .ready : .needsAttention
        )
        tap = TapDiagnosticSnapshot(
            state: appState.hotkeyMonitoringActive ? .ready : .needsAttention,
            disableCount: appState.diagnosticRuntimeState.tapDisableCount,
            rebuildCount: appState.diagnosticRuntimeState.tapRebuildCount,
            lastReason: appState.diagnosticRuntimeState.tapLastReason
        )

        let modelIsPreparing = appState.isInitializingEngine || appState.isDownloadingModel
        let modelState: DiagnosticHealthState
        if modelIsPreparing {
            modelState = .preparing
        } else if appState.engineReady {
            modelState = .ready
        } else {
            modelState = .unavailable
        }
        model = ModelDiagnosticSnapshot(
            selection: appState.asrSelection,
            state: modelState,
            phase: appState.diagnosticRuntimeState.modelPhase,
            preparationGeneration: appState.diagnosticRuntimeState.modelPreparationGeneration,
            ownedPath: appState.diagnosticRuntimeState.modelHasOwnedPath
                ? Self.expectedOwnedModelPath(for: appState.asrSelection)
                : nil,
            lastFailure: appState.diagnosticRuntimeState.modelLastFailure
        )

        let eouState: EOUDiagnosticState
        if appState.diagnosticRuntimeState.eou != .notObserved {
            eouState = appState.diagnosticRuntimeState.eou
        } else if appState.engineReady {
            // A prepared authoritative engine installs the local EOU preview
            // adapter, but does not imply that a preview session is active.
            eouState = .configured
        } else if modelIsPreparing {
            eouState = .preparing
        } else {
            eouState = .unavailable
        }
        eou = EOUDiagnosticSnapshot(state: eouState)

        let configurationState: DiagnosticHealthState
        if appState.configurationDiagnostic != nil {
            configurationState = .needsAttention
        } else if appState.configurationNotices.isEmpty {
            configurationState = .ready
        } else {
            configurationState = .degraded
        }
        configuration = ConfigurationDiagnosticSnapshot(
            state: configurationState,
            noticeCount: appState.configurationNotices.count,
            generation: appState.diagnosticRuntimeState.configurationGeneration,
            usingLastKnownGood: appState.diagnosticRuntimeState.configurationUsingLastKnownGood
        )

        switch appState.diagnosticRuntimeState.history {
        case .notLoaded:
            history = Self.unobservedHistory(state: .unknown)
        case .loading:
            history = Self.unobservedHistory(state: .preparing)
        case .unavailable:
            history = Self.unobservedHistory(state: .unavailable)
        case .available(let health):
            history = HistoryDiagnosticSnapshot(
                state: health.isOperational(
                    expectedMigrationIdentifiers: HistoryStore.expectedMigrationIdentifiers
                ) ? .ready : .needsAttention,
                journalMode: HistoryJournalDiagnosticState(journalMode: health.journalMode),
                migrationCount: health.appliedMigrationIdentifiers.count,
                entryCount: health.entryCount,
                pendingEntryCount: health.pendingEntryCount,
                retentionDays: health.retentionDays,
                integrityCheck: health.integrityCheckPassed ? .passed : .failed
            )
        }

        let insertionOutcome = appState.diagnosticRuntimeState.insertion
        insertion = InsertionDiagnosticSnapshot(
            state: insertionOutcome.health,
            lastOutcome: insertionOutcome,
            lastFailure: appState.diagnosticRuntimeState.insertionFailure
        )
    }

    var fields: [DiagnosticField] {
        [
            DiagnosticField(.schemaVersion, String(schemaVersion)),
            DiagnosticField(.microphonePermission, permissions.microphone.rawValue),
            DiagnosticField(.inputMonitoringPermission, permissions.inputMonitoring.rawValue),
            DiagnosticField(.accessibilityPermission, permissions.accessibility.rawValue),
            DiagnosticField(.tapState, tap.state.rawValue),
            DiagnosticField(.tapDisableCount, String(tap.disableCount)),
            DiagnosticField(.tapRebuildCount, String(tap.rebuildCount)),
            DiagnosticField(.tapLastReason, tap.lastReason.rawValue),
            DiagnosticField(.modelSelection, model.selection.rawValue),
            DiagnosticField(.modelState, model.state.rawValue),
            DiagnosticField(.modelPhase, model.phase.rawValue),
            DiagnosticField(
                .modelPreparationGeneration,
                String(model.preparationGeneration)
            ),
            DiagnosticField(.modelOwnedPath, model.ownedPath ?? "not_available"),
            DiagnosticField(.modelLastFailure, model.lastFailure.rawValue),
            DiagnosticField(.eouState, eou.state.rawValue),
            DiagnosticField(.configurationState, configuration.state.rawValue),
            DiagnosticField(.configurationNoticeCount, String(configuration.noticeCount)),
            DiagnosticField(.configurationGeneration, String(configuration.generation)),
            DiagnosticField(
                .configurationUsingLastKnownGood,
                String(configuration.usingLastKnownGood)
            ),
            DiagnosticField(.historyState, history.state.rawValue),
            DiagnosticField(.historyJournalMode, history.journalMode.rawValue),
            DiagnosticField(.historyMigrationCount, Self.render(history.migrationCount)),
            DiagnosticField(.historyEntryCount, Self.render(history.entryCount)),
            DiagnosticField(.historyPendingEntryCount, Self.render(history.pendingEntryCount)),
            DiagnosticField(.historyRetentionDays, Self.render(history.retentionDays)),
            DiagnosticField(.historyIntegrityCheck, history.integrityCheck.rawValue),
            DiagnosticField(.insertionState, insertion.state.rawValue),
            DiagnosticField(.insertionLastOutcome, insertion.lastOutcome.rawValue),
            DiagnosticField(.insertionLastFailure, insertion.lastFailure.rawValue),
        ]
    }

    var renderedReport: String {
        fields.map { "\($0.name.rawValue)=\($0.value)" }.joined(separator: "\n")
    }

    private static func unobservedHistory(
        state: DiagnosticHealthState
    ) -> HistoryDiagnosticSnapshot {
        HistoryDiagnosticSnapshot(
            state: state,
            journalMode: .notAvailable,
            migrationCount: nil,
            entryCount: nil,
            pendingEntryCount: nil,
            retentionDays: nil,
            integrityCheck: .notObserved
        )
    }

    private static func expectedOwnedModelPath(for selection: ASRSelection) -> String {
        "~/Library/Application Support/LocalDictation/Models/v1/"
            + selection.storageName
            + "/"
            + selection.adapterVersion
            + "/current"
    }

    private static func render(_ value: Int?) -> String {
        value.map(String.init) ?? "not_available"
    }
}
