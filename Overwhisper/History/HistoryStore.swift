import Foundation
import GRDB

/// Actor-isolated SQLite persistence for dictation history.
///
/// `DatabaseQueue` still serializes the synchronous database implementation,
/// while this actor keeps every public history operation off `MainActor`.
/// Saving the raw transcript can therefore finish before refinement or
/// insertion begins without exposing the database to UI code.
actor HistoryStore {
    static let schemaMigrationIdentifier = "history_v1"
    static let searchMigrationIdentifier = "history_fts_v1"
    static let searchBundleMigrationIdentifier = "history_fts_v2"
    static let metadataMigrationIdentifier = "history_metadata_v2"
    static let metricsMigrationIdentifier = "dictation_metrics_v1"
    static let unifiedMigrationIdentifier = "history_unified_v3"
    static let expectedMigrationIdentifiers = [
        schemaMigrationIdentifier,
        searchMigrationIdentifier,
        searchBundleMigrationIdentifier,
        metadataMigrationIdentifier,
        metricsMigrationIdentifier,
        unifiedMigrationIdentifier,
    ]

    private static let tableName = "dictation_history"
    private static let searchTableName = "dictation_history_fts"
    private static let metricsTableName = "dictation_metrics"
    private static let syncStateTableName = "history_sync_state"
    private static let syncOperationsTableName = "history_sync_operations"

    private enum Column {
        static let rowID = "row_id"
        static let id = "id"
        static let timestamp = "timestamp"
        static let rawText = "raw_text"
        static let polishedText = "polished_text"
        static let destinationBundleIdentifier = "destination_bundle_identifier"
        static let destinationDisplayName = "destination_display_name"
        static let mode = "mode"
        static let deliveryStatus = "delivery_status"
        static let refinementStatus = "refinement_status"
        static let asrLatency = "asr_latency"
        static let refinementLatency = "refinement_latency"
        static let totalLatency = "total_latency"
        static let unrecognizedCommandCandidatesJSON = "unrecognized_command_candidates_json"
        static let error = "error"
        static let polishRetryCount = "polish_retry_count"
        static let lastPolishAttemptAt = "last_polish_attempt_at"
        static let asrSelection = "asr_selection"
        static let asrOutcome = "asr_outcome"
        static let refinerBackend = "refiner_backend"
        static let refinementOutcome = "refinement_outcome"
        static let validationFailureKind = "validation_failure_kind"
        static let stopToPasteLatency = "stop_to_paste_latency"
        static let sourceKind = "source_kind"
        static let remoteRoute = "remote_route"
        static let cleanupBackend = "cleanup_backend"
        static let userEditedText = "user_edited_text"
        static let isPinned = "is_pinned"
        static let entryRevision = "entry_revision"
        static let updatedAt = "updated_at"
    }

    private enum SyncColumn {
        static let id = "id"
        static let globalRevision = "global_revision"
        static let opID = "op_id"
        static let entryID = "entry_id"
        static let status = "status"
        static let appliedAt = "applied_at"
    }

    private enum MetricsColumn {
        static let eventID = "event_id"
        static let completedAt = "completed_at"
        static let recordingDurationSeconds = "recording_duration_seconds"
        static let rawWordCount = "raw_word_count"
        static let deliveredWordCount = "delivered_word_count"
        static let dictationMode = "dictation_mode"
        static let speechEngine = "speech_engine"
        static let speechModel = "speech_model"
        static let cleanupBackend = "cleanup_backend"
        static let cleanupOutcome = "cleanup_outcome"
        static let asrLatencySeconds = "asr_latency_seconds"
        static let cleanupLatencySeconds = "cleanup_latency_seconds"
        static let stopToDeliveryLatencySeconds = "stop_to_delivery_latency_seconds"
        static let deliveryOutcome = "delivery_outcome"
        static let recognizedCommandCount = "recognized_command_count"
        static let wordsRemoved = "words_removed"
        static let destinationBundleIdentifier = "destination_bundle_identifier"
        static let destinationDisplayName = "destination_display_name"
        static let sourceKind = "source_kind"
        static let timingComplete = "timing_complete"
        static let createdAt = "created_at"
        static let updatedAt = "updated_at"
        static let eventRevision = "event_revision"
        static let schemaVersion = "schema_version"
    }

    private let database: DatabaseQueue

    init(databaseURL: URL) throws {
        let parentDirectory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.journalMode = .wal
        let database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try Self.enableSecureDeletion(in: database)
        self.database = database
        try Self.makeMigrator().migrate(database)
    }

    private init(database: DatabaseQueue) throws {
        try Self.enableSecureDeletion(in: database)
        self.database = database
        try Self.makeMigrator().migrate(database)
    }

    static func inMemory() throws -> HistoryStore {
        try HistoryStore(database: DatabaseQueue())
    }

    static func defaultDatabaseURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return base
            .appendingPathComponent(
                bundleIdentifier ?? "com.natemunk.LocalDictation",
                isDirectory: true
            )
            .appendingPathComponent("history.sqlite", isDirectory: false)
    }

    /// Opens an existing history database without migrating or writing it and
    /// reads only operational columns/PRAGMAs used by the diagnostics UI.
    static func readOnlyHealth(
        databaseURL: URL,
        policy: HistoryRetentionPolicy = .default
    ) throws -> HistoryStoreHealth {
        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(
            path: databaseURL.path,
            configuration: configuration
        )
        return try database.read { db in
            try makeHealth(in: db, policy: policy)
        }
    }

    /// Persists the immutable ASR result before any refinement or delivery is
    /// attempted. Later APIs never update `raw_text`.
    @discardableResult
    func saveRaw(_ capture: HistoryRawCapture) throws -> HistoryEntry {
        let candidatesJSON = try Self.encodeCandidates(capture.unrecognizedCommandCandidates)
        let refinementStatus: HistoryRefinementStatus = capture.refinementRequested
            ? .pending
            : .notRequested

        return try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(Self.tableName) (
                        \(Column.id),
                        \(Column.timestamp),
                        \(Column.rawText),
                        \(Column.destinationBundleIdentifier),
                        \(Column.destinationDisplayName),
                        \(Column.mode),
                        \(Column.deliveryStatus),
                        \(Column.refinementStatus),
                        \(Column.asrLatency),
                        \(Column.unrecognizedCommandCandidatesJSON),
                        \(Column.asrSelection),
                        \(Column.asrOutcome),
                        \(Column.sourceKind),
                        \(Column.updatedAt)
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    capture.id.uuidString.lowercased(),
                    capture.timestamp,
                    capture.rawText,
                    capture.destination.bundleIdentifier,
                    capture.destination.displayName,
                    capture.mode.rawValue,
                    HistoryDeliveryStatus.pending.rawValue,
                    refinementStatus.rawValue,
                    capture.asrLatency,
                    candidatesJSON,
                    capture.asrSelection,
                    capture.asrOutcome,
                    HistorySourceKind.desktop.rawValue,
                    capture.timestamp,
                ]
            )
            try Self.bumpGlobalRevision(in: db)

            return try Self.requireEntry(capture.id, in: db)
        }
    }

    /// Persists a finished remote (iPhone) transcription under its request ID.
    /// Replays of the same ID are idempotent and never rewrite stored text.
    @discardableResult
    func saveRemote(_ capture: HistoryRemoteCapture) throws -> (entry: HistoryEntry, inserted: Bool) {
        try database.write { db in
            try Self.saveRemoteCapture(capture, in: db)
        }
    }

    private static func saveRemoteCapture(
        _ capture: HistoryRemoteCapture,
        in db: Database
    ) throws -> (entry: HistoryEntry, inserted: Bool) {
        try db.execute(
            sql: """
                INSERT INTO \(Self.tableName) (
                    \(Column.id),
                    \(Column.timestamp),
                    \(Column.rawText),
                    \(Column.polishedText),
                    \(Column.mode),
                    \(Column.deliveryStatus),
                    \(Column.refinementStatus),
                    \(Column.asrLatency),
                    \(Column.refinementLatency),
                    \(Column.totalLatency),
                    \(Column.unrecognizedCommandCandidatesJSON),
                    \(Column.asrSelection),
                    \(Column.asrOutcome),
                    \(Column.refinerBackend),
                    \(Column.refinementOutcome),
                    \(Column.sourceKind),
                    \(Column.remoteRoute),
                    \(Column.cleanupBackend),
                    \(Column.updatedAt)
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '[]', ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(\(Column.id)) DO NOTHING
                """,
            arguments: [
                capture.id.uuidString.lowercased(),
                capture.timestamp,
                capture.rawText,
                capture.polishedText,
                capture.mode.rawValue,
                HistoryDeliveryStatus.delivered.rawValue,
                capture.refinementStatus.rawValue,
                capture.asrLatency,
                capture.refinementLatency,
                capture.totalLatency,
                capture.asrSelection,
                capture.asrOutcome,
                capture.refinerBackend,
                capture.refinementOutcome,
                capture.sourceKind.rawValue,
                capture.remoteRoute,
                capture.cleanupBackend,
                capture.timestamp,
            ]
        )
        let inserted = db.changesCount > 0
        if inserted {
            try Self.bumpGlobalRevision(in: db)
        }
        return (try Self.requireEntry(capture.id, in: db), inserted)
    }

    /// Consent is checked on this actor at persistence time, rather than when
    /// an iPhone request first entered the inference queue.
    func saveRemote(
        _ capture: HistoryRemoteCapture,
        authorization: HistoryPersistenceAuthorization
    ) throws -> (entry: HistoryEntry, inserted: Bool)? {
        try database.write { db in
            guard authorization.isCurrent else { return nil }
            return try Self.saveRemoteCapture(capture, in: db)
        }
    }

    /// Stores or clears the user's edit. Raw and polished text are untouched.
    /// A `baseRevision` guards against edits made from stale state.
    @discardableResult
    func setUserEditedText(
        id: UUID,
        text: String?,
        baseRevision: Int64? = nil
    ) throws -> HistoryEntry {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = (normalized?.isEmpty ?? true) ? nil : text
        if let stored, stored.count > HistorySyncManifest.maximumTextCharacters {
            throw HistoryStoreError.textTooLong(HistorySyncManifest.maximumTextCharacters)
        }
        return try database.write { db in
            let entry = try Self.requireEntry(id, in: db)
            try Self.requireRevision(entry, base: baseRevision)
            try db.execute(
                sql: """
                    UPDATE \(Self.tableName)
                    SET \(Column.userEditedText) = ?,
                        \(Column.entryRevision) = \(Column.entryRevision) + 1,
                        \(Column.updatedAt) = ?
                    WHERE \(Column.id) = ?
                    """,
                arguments: [stored, Date(), id.uuidString.lowercased()]
            )
            try Self.bumpGlobalRevision(in: db)
            return try Self.requireEntry(id, in: db)
        }
    }

    /// Pinned entries are exempt from retention pruning until unpinned.
    @discardableResult
    func setPinned(
        id: UUID,
        _ isPinned: Bool,
        baseRevision: Int64? = nil
    ) throws -> HistoryEntry {
        try database.write { db in
            let entry = try Self.requireEntry(id, in: db)
            try Self.requireRevision(entry, base: baseRevision)
            try db.execute(
                sql: """
                    UPDATE \(Self.tableName)
                    SET \(Column.isPinned) = ?,
                        \(Column.entryRevision) = \(Column.entryRevision) + 1,
                        \(Column.updatedAt) = ?
                    WHERE \(Column.id) = ?
                    """,
                arguments: [isPinned, Date(), id.uuidString.lowercased()]
            )
            try Self.bumpGlobalRevision(in: db)
            return try Self.requireEntry(id, in: db)
        }
    }

    /// Atomically records the polished output, refinement result, delivery
    /// result, and final timings while preserving the original raw transcript.
    @discardableResult
    func finalize(id: UUID, with finalization: HistoryFinalization) throws -> HistoryEntry {
        try database.write { db in
            _ = try Self.requireEntry(id, in: db)
            try db.execute(
                sql: """
                    UPDATE \(Self.tableName)
                    SET \(Column.entryRevision) = \(Column.entryRevision) + 1,
                        \(Column.updatedAt) = ?,
                        \(Column.polishedText) = ?,
                        \(Column.refinementStatus) = ?,
                        \(Column.deliveryStatus) = ?,
                        \(Column.refinementLatency) = ?,
                        \(Column.totalLatency) = ?,
                        \(Column.error) = ?,
                        \(Column.asrSelection) = COALESCE(?, \(Column.asrSelection)),
                        \(Column.asrOutcome) = COALESCE(?, \(Column.asrOutcome)),
                        \(Column.refinerBackend) = COALESCE(?, \(Column.refinerBackend)),
                        \(Column.refinementOutcome) = COALESCE(?, \(Column.refinementOutcome)),
                        \(Column.validationFailureKind) = COALESCE(?, \(Column.validationFailureKind)),
                        \(Column.stopToPasteLatency) = COALESCE(?, \(Column.stopToPasteLatency))
                    WHERE \(Column.id) = ?
                    """,
                arguments: [
                    Date(),
                    finalization.polishedText,
                    finalization.refinementStatus.rawValue,
                    finalization.deliveryStatus.rawValue,
                    finalization.refinementLatency,
                    finalization.totalLatency,
                    finalization.error,
                    finalization.asrSelection,
                    finalization.asrOutcome,
                    finalization.refinerBackend,
                    finalization.refinementOutcome,
                    finalization.validationFailureKind,
                    finalization.stopToPasteLatency,
                    id.uuidString.lowercased(),
                ]
            )
            try Self.bumpGlobalRevision(in: db)
            return try Self.requireEntry(id, in: db)
        }
    }

    /// Updates delivery independently when insertion finishes after refinement.
    /// A nil `deliveredText` leaves any existing polished output unchanged.
    @discardableResult
    func updateDelivery(id: UUID, with update: HistoryDeliveryUpdate) throws -> HistoryEntry {
        try database.write { db in
            _ = try Self.requireEntry(id, in: db)
            try db.execute(
                sql: """
                    UPDATE \(Self.tableName)
                    SET \(Column.entryRevision) = \(Column.entryRevision) + 1,
                        \(Column.updatedAt) = ?,
                        \(Column.polishedText) = COALESCE(?, \(Column.polishedText)),
                        \(Column.deliveryStatus) = ?,
                        \(Column.totalLatency) = COALESCE(?, \(Column.totalLatency)),
                        \(Column.error) = ?,
                        \(Column.asrSelection) = COALESCE(?, \(Column.asrSelection)),
                        \(Column.asrOutcome) = COALESCE(?, \(Column.asrOutcome)),
                        \(Column.refinerBackend) = COALESCE(?, \(Column.refinerBackend)),
                        \(Column.refinementOutcome) = COALESCE(?, \(Column.refinementOutcome)),
                        \(Column.validationFailureKind) = COALESCE(?, \(Column.validationFailureKind)),
                        \(Column.stopToPasteLatency) = COALESCE(?, \(Column.stopToPasteLatency))
                    WHERE \(Column.id) = ?
                    """,
                arguments: [
                    Date(),
                    update.deliveredText,
                    update.status.rawValue,
                    update.totalLatency,
                    update.error,
                    update.asrSelection,
                    update.asrOutcome,
                    update.refinerBackend,
                    update.refinementOutcome,
                    update.validationFailureKind,
                    update.stopToPasteLatency,
                    id.uuidString.lowercased(),
                ]
            )
            try Self.bumpGlobalRevision(in: db)
            return try Self.requireEntry(id, in: db)
        }
    }

    /// Records a failed clean-mode polish without changing the raw transcript.
    @discardableResult
    func markPolishFailed(
        id: UUID,
        error: String,
        deliveryStatus: HistoryDeliveryStatus = .failed,
        refinementLatency: TimeInterval? = nil,
        totalLatency: TimeInterval? = nil,
        at attemptedAt: Date = Date(),
        asrSelection: String? = nil,
        asrOutcome: String? = nil,
        refinerBackend: String? = nil,
        refinementOutcome: String? = nil,
        validationFailureKind: String? = nil,
        stopToPasteLatency: TimeInterval? = nil
    ) throws -> HistoryEntry {
        try database.write { db in
            _ = try Self.requireEntry(id, in: db)
            try db.execute(
                sql: """
                    UPDATE \(Self.tableName)
                    SET \(Column.entryRevision) = \(Column.entryRevision) + 1,
                        \(Column.updatedAt) = ?,
                        \(Column.refinementStatus) = ?,
                        \(Column.deliveryStatus) = ?,
                        \(Column.refinementLatency) = ?,
                        \(Column.totalLatency) = COALESCE(?, \(Column.totalLatency)),
                        \(Column.error) = ?,
                        \(Column.lastPolishAttemptAt) = ?,
                        \(Column.asrSelection) = COALESCE(?, \(Column.asrSelection)),
                        \(Column.asrOutcome) = COALESCE(?, \(Column.asrOutcome)),
                        \(Column.refinerBackend) = COALESCE(?, \(Column.refinerBackend)),
                        \(Column.refinementOutcome) = COALESCE(?, \(Column.refinementOutcome)),
                        \(Column.validationFailureKind) = COALESCE(?, \(Column.validationFailureKind)),
                        \(Column.stopToPasteLatency) = COALESCE(?, \(Column.stopToPasteLatency))
                    WHERE \(Column.id) = ?
                    """,
                arguments: [
                    attemptedAt,
                    HistoryRefinementStatus.failed.rawValue,
                    deliveryStatus.rawValue,
                    refinementLatency,
                    totalLatency,
                    error,
                    attemptedAt,
                    asrSelection,
                    asrOutcome,
                    refinerBackend,
                    refinementOutcome,
                    validationFailureKind,
                    stopToPasteLatency,
                    id.uuidString.lowercased(),
                ]
            )
            try Self.bumpGlobalRevision(in: db)
            return try Self.requireEntry(id, in: db)
        }
    }

    /// Marks a failed polish as retrying and returns the immutable raw text the
    /// caller should submit again. Retry metadata is updated atomically.
    @discardableResult
    func beginPolishRetry(id: UUID, at startedAt: Date = Date()) throws -> HistoryPolishRetry {
        try database.write { db in
            let entry = try Self.requireEntry(id, in: db)
            guard entry.refinementStatus == .failed else {
                throw HistoryStoreError.polishRetryRequiresFailedEntry(id)
            }

            let retryCount = entry.polishRetryCount + 1
            try db.execute(
                sql: """
                    UPDATE \(Self.tableName)
                    SET \(Column.entryRevision) = \(Column.entryRevision) + 1,
                        \(Column.updatedAt) = ?,
                        \(Column.refinementStatus) = ?,
                        \(Column.deliveryStatus) = CASE
                            WHEN \(Column.deliveryStatus) = ? THEN ?
                            ELSE \(Column.deliveryStatus)
                        END,
                        \(Column.polishRetryCount) = ?,
                        \(Column.lastPolishAttemptAt) = ?,
                        \(Column.refinementLatency) = NULL,
                        \(Column.totalLatency) = NULL,
                        \(Column.error) = NULL,
                        \(Column.refinerBackend) = NULL,
                        \(Column.refinementOutcome) = NULL,
                        \(Column.validationFailureKind) = NULL,
                        \(Column.stopToPasteLatency) = NULL
                    WHERE \(Column.id) = ?
                    """,
                arguments: [
                    startedAt,
                    HistoryRefinementStatus.retrying.rawValue,
                    HistoryDeliveryStatus.failed.rawValue,
                    HistoryDeliveryStatus.pending.rawValue,
                    retryCount,
                    startedAt,
                    id.uuidString.lowercased(),
                ]
            )
            try Self.bumpGlobalRevision(in: db)

            return HistoryPolishRetry(
                entryID: id,
                rawText: entry.rawText,
                retryCount: retryCount,
                startedAt: startedAt
            )
        }
    }

    func fetchRecent(limit: Int = 50) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM \(Self.tableName)
                    ORDER BY \(Column.timestamp) DESC, \(Column.rowID) DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return try rows.map(Self.decodeEntry)
        }
    }

    func search(_ query: String, limit: Int = 50) throws -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }

        return try database.read { db in
            if Self.canRepresentInFTS(normalizedQuery),
               let pattern = FTS5Pattern(matchingAllTokensIn: normalizedQuery) {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT history.*
                        FROM \(Self.tableName) AS history
                        JOIN \(Self.searchTableName)
                          ON \(Self.searchTableName).rowid = history.\(Column.rowID)
                        WHERE \(Self.searchTableName) MATCH ?
                        ORDER BY \(Self.searchTableName).rank,
                                 history.\(Column.timestamp) DESC
                        LIMIT ?
                        """,
                    arguments: [pattern, limit]
                )
                return try rows.map(Self.decodeEntry)
            }

            let likePattern = "%\(Self.escapeLikePattern(normalizedQuery))%"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT *
                    FROM \(Self.tableName)
                    WHERE LOWER(COALESCE(\(Column.rawText), '')) LIKE LOWER(?) ESCAPE '\\'
                       OR LOWER(COALESCE(\(Column.polishedText), '')) LIKE LOWER(?) ESCAPE '\\'
                       OR LOWER(COALESCE(\(Column.userEditedText), '')) LIKE LOWER(?) ESCAPE '\\'
                       OR LOWER(COALESCE(\(Column.destinationDisplayName), '')) LIKE LOWER(?) ESCAPE '\\'
                       OR LOWER(COALESCE(\(Column.destinationBundleIdentifier), '')) LIKE LOWER(?) ESCAPE '\\'
                    ORDER BY \(Column.timestamp) DESC, \(Column.rowID) DESC
                    LIMIT ?
                    """,
                arguments: [
                    likePattern,
                    likePattern,
                    likePattern,
                    likePattern,
                    likePattern,
                    limit,
                ]
            )
            return try rows.map(Self.decodeEntry)
        }
    }

    func fetch(id: UUID) throws -> HistoryEntry? {
        try database.read { db in
            try Self.fetchEntry(id, in: db)
        }
    }

    func text(for id: UUID, version: HistoryTextVersion) throws -> String? {
        guard let entry = try fetch(id: id) else {
            throw HistoryStoreError.entryNotFound(id)
        }
        return entry.text(for: version)
    }

    @discardableResult
    func delete(id: UUID) throws -> Bool {
        try database.write { db in
            guard try Self.fetchEntry(id, in: db) != nil else { return false }
            try db.execute(
                sql: "DELETE FROM \(Self.tableName) WHERE \(Column.id) = ?",
                arguments: [id.uuidString.lowercased()]
            )
            try Self.bumpGlobalRevision(in: db)
            return true
        }
    }

    @discardableResult
    func deleteAll() throws -> Int {
        try database.write { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(Self.tableName)"
            ) ?? 0
            try db.execute(sql: "DELETE FROM \(Self.tableName)")
            try db.execute(sql: "DELETE FROM \(Self.syncOperationsTableName)")
            try Self.bumpGlobalRevision(in: db)
            return count
        }
    }

    /// Explicit transcript-only deletion. Metrics intentionally have no
    /// foreign key to history and remain available after this operation.
    @discardableResult
    func deleteTranscriptHistory() throws -> Int {
        try deleteAll()
    }

    // MARK: - Transcript-free metrics

    /// Inserts or revises one attempt without ever accepting transcript text.
    /// A higher lifecycle revision wins even when asynchronous tasks complete
    /// out of order. Analytics-disabled callers perform no database write.
    @discardableResult
    func upsertMetric(
        _ event: DictationMetricEvent,
        analyticsEnabled: Bool = true
    ) throws -> Bool {
        guard analyticsEnabled else { return false }
        let now = Date()
        return try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(Self.metricsTableName) (
                        \(MetricsColumn.eventID),
                        \(MetricsColumn.completedAt),
                        \(MetricsColumn.recordingDurationSeconds),
                        \(MetricsColumn.rawWordCount),
                        \(MetricsColumn.deliveredWordCount),
                        \(MetricsColumn.dictationMode),
                        \(MetricsColumn.speechEngine),
                        \(MetricsColumn.speechModel),
                        \(MetricsColumn.cleanupBackend),
                        \(MetricsColumn.cleanupOutcome),
                        \(MetricsColumn.asrLatencySeconds),
                        \(MetricsColumn.cleanupLatencySeconds),
                        \(MetricsColumn.stopToDeliveryLatencySeconds),
                        \(MetricsColumn.deliveryOutcome),
                        \(MetricsColumn.recognizedCommandCount),
                        \(MetricsColumn.wordsRemoved),
                        \(MetricsColumn.destinationBundleIdentifier),
                        \(MetricsColumn.destinationDisplayName),
                        \(MetricsColumn.sourceKind),
                        \(MetricsColumn.timingComplete),
                        \(MetricsColumn.createdAt),
                        \(MetricsColumn.updatedAt),
                        \(MetricsColumn.eventRevision),
                        \(MetricsColumn.schemaVersion)
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(\(MetricsColumn.eventID)) DO UPDATE SET
                        \(MetricsColumn.completedAt) = excluded.\(MetricsColumn.completedAt),
                        \(MetricsColumn.recordingDurationSeconds) = excluded.\(MetricsColumn.recordingDurationSeconds),
                        \(MetricsColumn.rawWordCount) = excluded.\(MetricsColumn.rawWordCount),
                        \(MetricsColumn.deliveredWordCount) = excluded.\(MetricsColumn.deliveredWordCount),
                        \(MetricsColumn.dictationMode) = excluded.\(MetricsColumn.dictationMode),
                        \(MetricsColumn.speechEngine) = excluded.\(MetricsColumn.speechEngine),
                        \(MetricsColumn.speechModel) = excluded.\(MetricsColumn.speechModel),
                        \(MetricsColumn.cleanupBackend) = excluded.\(MetricsColumn.cleanupBackend),
                        \(MetricsColumn.cleanupOutcome) = excluded.\(MetricsColumn.cleanupOutcome),
                        \(MetricsColumn.asrLatencySeconds) = excluded.\(MetricsColumn.asrLatencySeconds),
                        \(MetricsColumn.cleanupLatencySeconds) = excluded.\(MetricsColumn.cleanupLatencySeconds),
                        \(MetricsColumn.stopToDeliveryLatencySeconds) = excluded.\(MetricsColumn.stopToDeliveryLatencySeconds),
                        \(MetricsColumn.deliveryOutcome) = excluded.\(MetricsColumn.deliveryOutcome),
                        \(MetricsColumn.recognizedCommandCount) = excluded.\(MetricsColumn.recognizedCommandCount),
                        \(MetricsColumn.wordsRemoved) = excluded.\(MetricsColumn.wordsRemoved),
                        \(MetricsColumn.destinationBundleIdentifier) = excluded.\(MetricsColumn.destinationBundleIdentifier),
                        \(MetricsColumn.destinationDisplayName) = excluded.\(MetricsColumn.destinationDisplayName),
                        \(MetricsColumn.sourceKind) = excluded.\(MetricsColumn.sourceKind),
                        \(MetricsColumn.timingComplete) = excluded.\(MetricsColumn.timingComplete),
                        \(MetricsColumn.updatedAt) = excluded.\(MetricsColumn.updatedAt),
                        \(MetricsColumn.eventRevision) = excluded.\(MetricsColumn.eventRevision),
                        \(MetricsColumn.schemaVersion) = excluded.\(MetricsColumn.schemaVersion)
                    WHERE excluded.\(MetricsColumn.eventRevision) > \(Self.metricsTableName).\(MetricsColumn.eventRevision)
                    """,
                arguments: [
                    event.eventID.uuidString.lowercased(),
                    event.completedAt,
                    event.recordingDurationSeconds,
                    max(0, event.rawWordCount),
                    max(0, event.deliveredWordCount),
                    event.dictationMode,
                    event.speechEngine,
                    event.speechModel,
                    event.cleanupBackend,
                    event.cleanupOutcome,
                    event.asrLatencySeconds,
                    event.cleanupLatencySeconds,
                    event.stopToDeliveryLatencySeconds,
                    event.deliveryOutcome,
                    event.recognizedCommandCount,
                    event.wordsRemoved,
                    event.destinationBundleIdentifier,
                    event.destinationDisplayName,
                    event.sourceKind.rawValue,
                    event.timingComplete,
                    now,
                    now,
                    event.eventRevision,
                    event.schemaVersion,
                ]
            )
            return db.changesCount > 0
        }
    }

    func fetchMetric(eventID: UUID) throws -> DictationMetricEvent? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM \(Self.metricsTableName) WHERE \(MetricsColumn.eventID) = ?",
                arguments: [eventID.uuidString.lowercased()]
            ) else { return nil }
            return try Self.decodeMetric(row)
        }
    }

    func fetchMetrics(limit: Int = 100) throws -> [DictationMetricEvent] {
        guard limit > 0 else { return [] }
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM \(Self.metricsTableName)
                    ORDER BY \(MetricsColumn.completedAt) DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            ).map(Self.decodeMetric)
        }
    }

    func metricCount(sourceKind: DictationMetricSourceKind? = nil) throws -> Int {
        try database.read { db in
            if let sourceKind {
                return try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM \(Self.metricsTableName) WHERE \(MetricsColumn.sourceKind) = ?",
                    arguments: [sourceKind.rawValue]
                ) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(Self.metricsTableName)") ?? 0
        }
    }

    /// Repair/test seam for the same insert-only backfill used by the migration.
    /// It is deliberately not called on every launch so Reset Analytics remains
    /// durable while transcript history is retained.
    @discardableResult
    func backfillLegacyMetrics() throws -> Int {
        try database.write { db in
            try Self.backfillLegacyMetrics(in: db)
        }
    }

    @discardableResult
    func resetAnalytics() throws -> Int {
        try database.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(Self.metricsTableName)") ?? 0
            try db.execute(sql: "DELETE FROM \(Self.metricsTableName)")
            return count
        }
    }

    @discardableResult
    func deleteEverything() throws -> (history: Int, metrics: Int) {
        let deleted = try database.write { db in
            let history = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(Self.tableName)"
            ) ?? 0
            let metrics = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(Self.metricsTableName)"
            ) ?? 0
            try db.execute(sql: "DELETE FROM \(Self.tableName)")
            try db.execute(sql: "DELETE FROM \(Self.metricsTableName)")
            try db.execute(sql: "DELETE FROM \(Self.syncOperationsTableName)")
            try Self.bumpGlobalRevision(in: db)
            return (history, metrics)
        }
        // A logical DELETE alone can leave prior values in free pages or the
        // WAL. This explicit destructive action also checkpoints and rebuilds
        // the database so deleted transcript text and destination metadata do
        // not remain recoverable from ordinary database files.
        try database.writeWithoutTransaction { db in
            _ = try db.checkpoint(.truncate)
            try db.execute(sql: "VACUUM")
            _ = try db.checkpoint(.truncate)
        }
        return deleted
    }

    /// Removes every history entry older than the policy cutoff, regardless of
    /// delivery or refinement outcome. Callers can use this at launch and from
    /// a daily maintenance task.
    @discardableResult
    func pruneEntries(
        policy: HistoryRetentionPolicy = .default,
        relativeTo now: Date = Date()
    ) throws -> Int {
        guard policy.retentionDays >= 0 else {
            throw HistoryStoreError.invalidRetentionDays(policy.retentionDays)
        }

        let cutoff = now.addingTimeInterval(
            -TimeInterval(policy.retentionDays) * 24 * 60 * 60
        )

        return try database.write { db in
            let count = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM \(Self.tableName)
                    WHERE \(Column.timestamp) < ? AND \(Column.isPinned) = 0
                    """,
                arguments: [cutoff]
            ) ?? 0
            guard count > 0 else { return 0 }
            try db.execute(
                sql: """
                    DELETE FROM \(Self.tableName)
                    WHERE \(Column.timestamp) < ? AND \(Column.isPinned) = 0
                    """,
                arguments: [cutoff]
            )
            try Self.bumpGlobalRevision(in: db)
            return count
        }
    }

    /// Compatibility shim for the pre-v2 successful-delivery-only name. The
    /// retention policy now applies to all entry states.
    @discardableResult
    func pruneSuccessfulEntries(
        policy: HistoryRetentionPolicy = .default,
        relativeTo now: Date = Date()
    ) throws -> Int {
        try pruneEntries(policy: policy, relativeTo: now)
    }

    // MARK: - Unified history synchronization

    private static func bumpGlobalRevision(in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE \(syncStateTableName)
                SET \(SyncColumn.globalRevision) = \(SyncColumn.globalRevision) + 1
                WHERE \(SyncColumn.id) = 1
                """
        )
    }

    private static func currentGlobalRevision(in db: Database) throws -> Int64 {
        try Int64.fetchOne(
            db,
            sql: "SELECT \(SyncColumn.globalRevision) FROM \(syncStateTableName) WHERE \(SyncColumn.id) = 1"
        ) ?? 0
    }

    private static func requireRevision(_ entry: HistoryEntry, base: Int64?) throws {
        if let base, base != entry.entryRevision {
            throw HistoryStoreError.revisionConflict(entry.id, currentRevision: entry.entryRevision)
        }
    }

    func globalRevision() throws -> Int64 {
        try database.read { db in try Self.currentGlobalRevision(in: db) }
    }

    func syncManifest(policy: HistoryRetentionPolicy = .default) throws -> HistorySyncManifest {
        try database.read { db in
            let revision = try Self.currentGlobalRevision(in: db)
            let entryCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(Self.tableName)") ?? 0
            let pinnedCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(Self.tableName) WHERE \(Column.isPinned) = 1"
            ) ?? 0
            return HistorySyncManifest(
                revision: revision,
                entryCount: entryCount,
                pinnedCount: pinnedCount,
                retention: .standard(unpinnedDays: policy.retentionDays),
                maxOperationsPerRequest: HistorySyncManifest.maximumOperationsPerRequest,
                maxTextCharacters: HistorySyncManifest.maximumTextCharacters
            )
        }
    }

    /// One page of a consistent snapshot. The caller pins `revision`; any
    /// intervening mutation makes the page request fail with the new revision
    /// so the client restarts instead of merging two different states.
    func syncPage(revision: Int64, cursor: String?, limit: Int) throws -> HistorySyncPage {
        guard limit >= 1, limit <= HistorySyncManifest.maximumPageSize else {
            throw HistorySyncError.invalidRequest
        }
        var cursorRowID: Int64?
        if let cursor {
            guard cursor.count <= 64, let parsed = Int64(cursor), parsed >= 0 else {
                throw HistorySyncError.invalidRequest
            }
            cursorRowID = parsed
        }

        return try database.read { db in
            let current = try Self.currentGlobalRevision(in: db)
            guard current == revision else {
                throw HistorySyncError.historyChanged(currentRevision: current)
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM \(Self.tableName)
                    WHERE (? IS NULL OR \(Column.rowID) < ?)
                    ORDER BY \(Column.rowID) DESC
                    LIMIT ?
                    """,
                arguments: [cursorRowID, cursorRowID, limit + 1]
            )
            let page = Array(rows.prefix(limit))
            let nextCursor: String? = rows.count > limit
                ? String(page.last.map { $0[Column.rowID] as Int64 } ?? 0)
                : nil
            let entries = try page.map(Self.decodeEntry).map(HistorySyncEntry.init)
            return HistorySyncPage(revision: current, entries: entries, nextCursor: nextCursor)
        }
    }

    /// Applies client operations idempotently inside one transaction. Each
    /// operation is judged on its own; neighbours are never rolled back.
    func applySyncOperations(_ batch: HistorySyncOperationBatch) throws -> HistorySyncOperationBatchResult {
        guard !batch.operations.isEmpty,
              batch.operations.count <= HistorySyncManifest.maximumOperationsPerRequest
        else { throw HistorySyncError.invalidRequest }

        return try database.write { db in
            var results: [HistorySyncOperationResult] = []
            var appliedAny = false
            let now = Date()

            for operation in batch.operations {
                let result = try Self.apply(operation, at: now, in: db)
                if result.status == .applied {
                    appliedAny = true
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO \(Self.syncOperationsTableName) (
                                \(SyncColumn.opID), \(SyncColumn.entryID), \(SyncColumn.status), \(SyncColumn.appliedAt)
                            ) VALUES (?, ?, ?, ?)
                            """,
                        arguments: [
                            operation.opID.uuidString.lowercased(),
                            operation.entryID.uuidString.lowercased(),
                            result.status.rawValue,
                            now,
                        ]
                    )
                }
                results.append(result)
            }
            if appliedAny {
                try Self.bumpGlobalRevision(in: db)
            }
            return HistorySyncOperationBatchResult(
                revision: try Self.currentGlobalRevision(in: db),
                results: results
            )
        }
    }

    private static let acceptedRemoteRoutes: Set<String> = ["mac_local", "cloud_fallback"]
    private static let acceptedCleanupBackends: Set<String> = ["apple_foundation", "deterministic", "none"]

    private static func apply(
        _ operation: HistorySyncOperation,
        at now: Date,
        in db: Database
    ) throws -> HistorySyncOperationResult {
        let opID = operation.opID.uuidString.lowercased()
        let alreadyApplied = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(syncOperationsTableName) WHERE \(SyncColumn.opID) = ?",
            arguments: [opID]
        ) ?? 0
        let existing = try fetchEntry(operation.entryID, in: db)
        if alreadyApplied > 0 {
            return HistorySyncOperationResult(
                opID: operation.opID,
                status: .alreadyApplied,
                entry: existing.map(HistorySyncEntry.init)
            )
        }

        switch operation.type {
        case .import:
            guard let sourceKind = operation.sourceKind, sourceKind != .desktop,
                  let mode = operation.mode,
                  let text = operation.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= HistorySyncManifest.maximumTextCharacters,
                  let route = operation.route, acceptedRemoteRoutes.contains(route)
            else {
                return HistorySyncOperationResult(opID: operation.opID, status: .invalid, entry: nil)
            }
            let cleanup = operation.cleanup ?? "none"
            guard acceptedCleanupBackends.contains(cleanup) else {
                return HistorySyncOperationResult(opID: operation.opID, status: .invalid, entry: nil)
            }
            if let existing {
                return HistorySyncOperationResult(
                    opID: operation.opID,
                    status: .alreadyApplied,
                    entry: HistorySyncEntry(existing)
                )
            }
            let timestamp = operation.createdAt ?? now
            try db.execute(
                sql: """
                    INSERT INTO \(tableName) (
                        \(Column.id), \(Column.timestamp), \(Column.rawText), \(Column.polishedText),
                        \(Column.mode), \(Column.deliveryStatus), \(Column.refinementStatus),
                        \(Column.unrecognizedCommandCandidatesJSON), \(Column.sourceKind),
                        \(Column.remoteRoute), \(Column.cleanupBackend), \(Column.updatedAt)
                    ) VALUES (?, ?, ?, NULL, ?, ?, ?, '[]', ?, ?, ?, ?)
                    """,
                arguments: [
                    operation.entryID.uuidString.lowercased(),
                    timestamp,
                    text,
                    mode.rawValue,
                    HistoryDeliveryStatus.delivered.rawValue,
                    HistoryRefinementStatus.notRequested.rawValue,
                    sourceKind.rawValue,
                    route,
                    cleanup,
                    now,
                ]
            )
            let inserted = try requireEntry(operation.entryID, in: db)
            return HistorySyncOperationResult(opID: operation.opID, status: .applied, entry: HistorySyncEntry(inserted))

        case .edit, .pin, .unpin:
            guard let entry = existing else {
                return HistorySyncOperationResult(opID: operation.opID, status: .missing, entry: nil)
            }
            guard let base = operation.baseRevision else {
                return HistorySyncOperationResult(opID: operation.opID, status: .invalid, entry: HistorySyncEntry(entry))
            }
            guard base == entry.entryRevision else {
                return HistorySyncOperationResult(opID: operation.opID, status: .conflict, entry: HistorySyncEntry(entry))
            }
            if operation.type == .edit {
                let trimmed = operation.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.count > HistorySyncManifest.maximumTextCharacters {
                    return HistorySyncOperationResult(opID: operation.opID, status: .invalid, entry: HistorySyncEntry(entry))
                }
                try db.execute(
                    sql: """
                        UPDATE \(tableName)
                        SET \(Column.userEditedText) = ?,
                            \(Column.entryRevision) = \(Column.entryRevision) + 1,
                            \(Column.updatedAt) = ?
                        WHERE \(Column.id) = ?
                        """,
                    arguments: [trimmed.isEmpty ? nil : operation.text, now, operation.entryID.uuidString.lowercased()]
                )
            } else {
                try db.execute(
                    sql: """
                        UPDATE \(tableName)
                        SET \(Column.isPinned) = ?,
                            \(Column.entryRevision) = \(Column.entryRevision) + 1,
                            \(Column.updatedAt) = ?
                        WHERE \(Column.id) = ?
                        """,
                    arguments: [operation.type == .pin, now, operation.entryID.uuidString.lowercased()]
                )
            }
            let updated = try requireEntry(operation.entryID, in: db)
            return HistorySyncOperationResult(opID: operation.opID, status: .applied, entry: HistorySyncEntry(updated))

        case .delete:
            guard let entry = existing else {
                return HistorySyncOperationResult(opID: operation.opID, status: .alreadyApplied, entry: nil)
            }
            guard let base = operation.baseRevision else {
                return HistorySyncOperationResult(opID: operation.opID, status: .invalid, entry: HistorySyncEntry(entry))
            }
            guard base == entry.entryRevision else {
                return HistorySyncOperationResult(opID: operation.opID, status: .conflict, entry: HistorySyncEntry(entry))
            }
            try db.execute(
                sql: "DELETE FROM \(tableName) WHERE \(Column.id) = ?",
                arguments: [operation.entryID.uuidString.lowercased()]
            )
            return HistorySyncOperationResult(opID: operation.opID, status: .applied, entry: nil)
        }
    }

    // MARK: - Migration and schema diagnostics

    private static func enableSecureDeletion(in database: DatabaseQueue) throws {
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
    }

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration(schemaMigrationIdentifier) { db in
            try db.create(table: tableName) { table in
                table.autoIncrementedPrimaryKey(Column.rowID)
                table.column(Column.id, .text).notNull().unique()
                table.column(Column.timestamp, .datetime).notNull().indexed()
                table.column(Column.rawText, .text).notNull()
                table.column(Column.polishedText, .text)
                table.column(Column.destinationBundleIdentifier, .text)
                table.column(Column.destinationDisplayName, .text)
                table.column(Column.mode, .text).notNull()
                table.column(Column.deliveryStatus, .text).notNull()
                table.column(Column.refinementStatus, .text).notNull()
                table.column(Column.asrLatency, .double)
                table.column(Column.refinementLatency, .double)
                table.column(Column.totalLatency, .double)
                table.column(Column.unrecognizedCommandCandidatesJSON, .text)
                    .notNull()
                    .defaults(to: "[]")
                table.column(Column.error, .text)
                table.column(Column.polishRetryCount, .integer)
                    .notNull()
                    .defaults(to: 0)
                table.column(Column.lastPolishAttemptAt, .datetime)
            }
        }

        migrator.registerMigration(searchMigrationIdentifier) { db in
            try db.create(virtualTable: searchTableName, using: FTS5()) { table in
                table.synchronize(withTable: tableName)
                table.column(Column.rawText)
                table.column(Column.polishedText)
                table.column(Column.destinationDisplayName)
            }
        }

        migrator.registerMigration(searchBundleMigrationIdentifier) { db in
            try db.drop(table: searchTableName)
            try db.dropFTS5SynchronizationTriggers(forTable: searchTableName)
            try db.create(virtualTable: searchTableName, using: FTS5()) { table in
                table.synchronize(withTable: tableName)
                table.column(Column.rawText)
                table.column(Column.polishedText)
                table.column(Column.destinationDisplayName)
                table.column(Column.destinationBundleIdentifier)
            }
        }

        migrator.registerMigration(metadataMigrationIdentifier) { db in
            try db.alter(table: tableName) { table in
                table.add(column: Column.asrSelection, .text)
                table.add(column: Column.asrOutcome, .text)
                table.add(column: Column.refinerBackend, .text)
                table.add(column: Column.refinementOutcome, .text)
                table.add(column: Column.validationFailureKind, .text)
                table.add(column: Column.stopToPasteLatency, .double)
            }
        }

        migrator.registerMigration(metricsMigrationIdentifier) { db in
            try db.create(table: metricsTableName) { table in
                table.column(MetricsColumn.eventID, .text).primaryKey()
                table.column(MetricsColumn.completedAt, .datetime).notNull().indexed()
                table.column(MetricsColumn.recordingDurationSeconds, .double)
                table.column(MetricsColumn.rawWordCount, .integer).notNull().defaults(to: 0)
                table.column(MetricsColumn.deliveredWordCount, .integer).notNull().defaults(to: 0)
                table.column(MetricsColumn.dictationMode, .text)
                table.column(MetricsColumn.speechEngine, .text)
                table.column(MetricsColumn.speechModel, .text)
                table.column(MetricsColumn.cleanupBackend, .text)
                table.column(MetricsColumn.cleanupOutcome, .text)
                table.column(MetricsColumn.asrLatencySeconds, .double)
                table.column(MetricsColumn.cleanupLatencySeconds, .double)
                table.column(MetricsColumn.stopToDeliveryLatencySeconds, .double)
                table.column(MetricsColumn.deliveryOutcome, .text).notNull()
                table.column(MetricsColumn.recognizedCommandCount, .integer)
                table.column(MetricsColumn.wordsRemoved, .integer)
                table.column(MetricsColumn.destinationBundleIdentifier, .text)
                table.column(MetricsColumn.destinationDisplayName, .text)
                table.column(MetricsColumn.sourceKind, .text).notNull()
                table.column(MetricsColumn.timingComplete, .boolean)
                    .notNull()
                    .defaults(to: false)
                table.column(MetricsColumn.createdAt, .datetime).notNull()
                table.column(MetricsColumn.updatedAt, .datetime).notNull()
                table.column(MetricsColumn.eventRevision, .integer)
                    .notNull()
                    .defaults(to: 0)
                table.column(MetricsColumn.schemaVersion, .integer)
                    .notNull()
                    .defaults(to: DictationMetricEvent.currentSchemaVersion)
            }
            _ = try backfillLegacyMetrics(in: db)
        }

        migrator.registerMigration(unifiedMigrationIdentifier) { db in
            try db.alter(table: tableName) { table in
                table.add(column: Column.sourceKind, .text)
                    .notNull()
                    .defaults(to: HistorySourceKind.desktop.rawValue)
                table.add(column: Column.remoteRoute, .text)
                table.add(column: Column.cleanupBackend, .text)
                table.add(column: Column.userEditedText, .text)
                table.add(column: Column.isPinned, .boolean).notNull().defaults(to: false)
                table.add(column: Column.entryRevision, .integer).notNull().defaults(to: 1)
                table.add(column: Column.updatedAt, .datetime)
            }
            try db.execute(
                sql: """
                    UPDATE \(tableName)
                    SET \(Column.updatedAt) = \(Column.timestamp)
                    WHERE \(Column.updatedAt) IS NULL
                    """
            )
            try db.create(index: "\(tableName)_pinned_timestamp", on: tableName, columns: [Column.isPinned, Column.timestamp])

            try db.create(table: syncStateTableName) { table in
                table.column(SyncColumn.id, .integer).primaryKey().check { $0 == 1 }
                table.column(SyncColumn.globalRevision, .integer).notNull().defaults(to: 1)
            }
            try db.execute(
                sql: "INSERT INTO \(syncStateTableName) (\(SyncColumn.id), \(SyncColumn.globalRevision)) VALUES (1, 1)"
            )
            try db.create(table: syncOperationsTableName) { table in
                table.column(SyncColumn.opID, .text).primaryKey()
                table.column(SyncColumn.entryID, .text).notNull()
                table.column(SyncColumn.status, .text).notNull()
                table.column(SyncColumn.appliedAt, .datetime).notNull()
            }

            try db.drop(table: searchTableName)
            try db.dropFTS5SynchronizationTriggers(forTable: searchTableName)
            try db.create(virtualTable: searchTableName, using: FTS5()) { table in
                table.synchronize(withTable: tableName)
                table.column(Column.rawText)
                table.column(Column.polishedText)
                table.column(Column.userEditedText)
                table.column(Column.destinationDisplayName)
                table.column(Column.destinationBundleIdentifier)
            }
        }

        return migrator
    }

    func appliedMigrationIdentifiers() throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
            )
        }
    }

    /// Returns only operational metadata. No transcript, destination text, or
    /// error text is included, so this can be used for launch diagnostics.
    func health(policy: HistoryRetentionPolicy = .default) throws -> HistoryStoreHealth {
        try database.read { db in
            try Self.makeHealth(in: db, policy: policy)
        }
    }

    private static func makeHealth(
        in db: Database,
        policy: HistoryRetentionPolicy
    ) throws -> HistoryStoreHealth {
        let journalMode = (
            try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
        ).lowercased()
        let migrations = try String.fetchAll(
            db,
            sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
        )
        let entryCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(Self.tableName)"
        ) ?? 0
        let pendingEntryCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(Self.tableName) WHERE \(Column.deliveryStatus) = ?",
            arguments: [HistoryDeliveryStatus.pending.rawValue]
        ) ?? 0
        let lastDeliveryRaw = try String.fetchOne(
            db,
            sql: """
                SELECT \(Column.deliveryStatus)
                FROM \(Self.tableName)
                ORDER BY \(Column.timestamp) DESC, \(Column.rowID) DESC
                LIMIT 1
                """
        )
        let lastDeliveryStatus = lastDeliveryRaw.flatMap(HistoryDeliveryStatus.init(rawValue:))
        let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check(1)")
        let integrityCheckPassed = quickCheck?.lowercased() == "ok"
            && (lastDeliveryRaw == nil || lastDeliveryStatus != nil)

        return HistoryStoreHealth(
            journalMode: journalMode,
            appliedMigrationIdentifiers: migrations,
            retentionPolicy: policy,
            entryCount: entryCount,
            pendingEntryCount: pendingEntryCount,
            lastDeliveryStatus: lastDeliveryStatus,
            integrityCheckPassed: integrityCheckPassed
        )
    }

    func databaseColumnNames() throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('\(Self.tableName)') ORDER BY cid"
            )
        }
    }

    func metricsDatabaseColumnNames() throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('\(Self.metricsTableName)') ORDER BY cid"
            )
        }
    }

    func metricsForeignKeyCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_foreign_key_list('\(Self.metricsTableName)')"
            ) ?? 0
        }
    }

    func databaseSchemaObjectNames() throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name
                    FROM sqlite_master
                    WHERE type IN ('table', 'trigger', 'index')
                    ORDER BY name
                    """
            )
        }
    }

    // MARK: - Record mapping

    private static func backfillLegacyMetrics(in db: Database) throws -> Int {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT
                    \(Column.id),
                    \(Column.timestamp),
                    \(Column.rawText),
                    \(Column.polishedText),
                    \(Column.destinationBundleIdentifier),
                    \(Column.destinationDisplayName),
                    \(Column.mode),
                    \(Column.deliveryStatus),
                    \(Column.refinementStatus),
                    \(Column.refinementLatency),
                    \(Column.refinementOutcome),
                    \(Column.stopToPasteLatency)
                FROM \(tableName)
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM \(metricsTableName)
                    WHERE \(metricsTableName).\(MetricsColumn.eventID) = \(tableName).\(Column.id)
                )
                """
        )
        let now = Date()
        var insertedCount = 0

        for row in rows {
            let storedID: String = row[Column.id]
            guard UUID(uuidString: storedID) != nil else { continue }
            let rawText: String = row[Column.rawText]
            let polishedText: String? = row[Column.polishedText]
            let mode: String = row[Column.mode]
            let deliveryOutcome: String = row[Column.deliveryStatus]
            let refinementStatus: String = row[Column.refinementStatus]
            let refinementOutcome: String? = row[Column.refinementOutcome]
            let deliveredText = polishedText ?? rawText
            let rawWordCount = DictationWordCounter.count(rawText)
            let deliveredWordCount = legacyOutcomeMakesTextAvailable(deliveryOutcome)
                ? DictationWordCounter.count(deliveredText)
                : 0
            let cleanupRan = mode == HistoryDictationMode.clean.rawValue
                && polishedText != nil
                && refinementStatus != HistoryRefinementStatus.pending.rawValue
                && refinementStatus != HistoryRefinementStatus.notRequested.rawValue
            let wordsRemoved = cleanupRan
                ? max(0, rawWordCount - DictationWordCounter.count(deliveredText))
                : nil

            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO \(metricsTableName) (
                        \(MetricsColumn.eventID),
                        \(MetricsColumn.completedAt),
                        \(MetricsColumn.recordingDurationSeconds),
                        \(MetricsColumn.rawWordCount),
                        \(MetricsColumn.deliveredWordCount),
                        \(MetricsColumn.dictationMode),
                        \(MetricsColumn.speechEngine),
                        \(MetricsColumn.speechModel),
                        \(MetricsColumn.cleanupBackend),
                        \(MetricsColumn.cleanupOutcome),
                        \(MetricsColumn.asrLatencySeconds),
                        \(MetricsColumn.cleanupLatencySeconds),
                        \(MetricsColumn.stopToDeliveryLatencySeconds),
                        \(MetricsColumn.deliveryOutcome),
                        \(MetricsColumn.recognizedCommandCount),
                        \(MetricsColumn.wordsRemoved),
                        \(MetricsColumn.destinationBundleIdentifier),
                        \(MetricsColumn.destinationDisplayName),
                        \(MetricsColumn.sourceKind),
                        \(MetricsColumn.timingComplete),
                        \(MetricsColumn.createdAt),
                        \(MetricsColumn.updatedAt),
                        \(MetricsColumn.eventRevision),
                        \(MetricsColumn.schemaVersion)
                    ) VALUES (?, ?, NULL, ?, ?, ?, NULL, NULL, NULL, ?, NULL, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                    """,
                arguments: [
                    storedID.lowercased(),
                    row[Column.timestamp] as Date,
                    rawWordCount,
                    deliveredWordCount,
                    mode,
                    refinementOutcome ?? refinementStatus,
                    row[Column.refinementLatency] as TimeInterval?,
                    row[Column.stopToPasteLatency] as TimeInterval?,
                    deliveryOutcome,
                    wordsRemoved,
                    row[Column.destinationBundleIdentifier] as String?,
                    row[Column.destinationDisplayName] as String?,
                    DictationMetricSourceKind.legacyHistory.rawValue,
                    false,
                    now,
                    now,
                    DictationMetricEvent.currentSchemaVersion,
                ]
            )
            insertedCount += db.changesCount
        }
        return insertedCount
    }

    private static func legacyOutcomeMakesTextAvailable(_ rawValue: String) -> Bool {
        guard let status = HistoryDeliveryStatus(rawValue: rawValue) else { return false }
        switch status {
        case .delivered, .previewed, .pastedRaw, .pasteEventSent, .clipboardOnly:
            return true
        case .pending, .historyOnly, .failed, .cancelled:
            return false
        }
    }

    private static func decodeMetric(_ row: Row) throws -> DictationMetricEvent {
        let storedID: String = row[MetricsColumn.eventID]
        guard let eventID = UUID(uuidString: storedID) else {
            throw HistoryStoreError.invalidStoredValue(
                column: MetricsColumn.eventID,
                value: storedID
            )
        }
        let storedSourceKind: String = row[MetricsColumn.sourceKind]
        guard let sourceKind = DictationMetricSourceKind(rawValue: storedSourceKind) else {
            throw HistoryStoreError.invalidStoredValue(
                column: MetricsColumn.sourceKind,
                value: storedSourceKind
            )
        }

        return DictationMetricEvent(
            eventID: eventID,
            completedAt: row[MetricsColumn.completedAt],
            recordingDurationSeconds: row[MetricsColumn.recordingDurationSeconds],
            rawWordCount: row[MetricsColumn.rawWordCount],
            deliveredWordCount: row[MetricsColumn.deliveredWordCount],
            dictationMode: row[MetricsColumn.dictationMode],
            speechEngine: row[MetricsColumn.speechEngine],
            speechModel: row[MetricsColumn.speechModel],
            cleanupBackend: row[MetricsColumn.cleanupBackend],
            cleanupOutcome: row[MetricsColumn.cleanupOutcome],
            asrLatencySeconds: row[MetricsColumn.asrLatencySeconds],
            cleanupLatencySeconds: row[MetricsColumn.cleanupLatencySeconds],
            stopToDeliveryLatencySeconds: row[MetricsColumn.stopToDeliveryLatencySeconds],
            deliveryOutcome: row[MetricsColumn.deliveryOutcome],
            recognizedCommandCount: row[MetricsColumn.recognizedCommandCount],
            wordsRemoved: row[MetricsColumn.wordsRemoved],
            destinationBundleIdentifier: row[MetricsColumn.destinationBundleIdentifier],
            destinationDisplayName: row[MetricsColumn.destinationDisplayName],
            sourceKind: sourceKind,
            timingComplete: row[MetricsColumn.timingComplete],
            eventRevision: row[MetricsColumn.eventRevision],
            schemaVersion: row[MetricsColumn.schemaVersion]
        )
    }

    private static func fetchEntry(_ id: UUID, in db: Database) throws -> HistoryEntry? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM \(tableName) WHERE \(Column.id) = ?",
            arguments: [id.uuidString.lowercased()]
        ) else {
            return nil
        }
        return try decodeEntry(row)
    }

    private static func requireEntry(_ id: UUID, in db: Database) throws -> HistoryEntry {
        guard let entry = try fetchEntry(id, in: db) else {
            throw HistoryStoreError.entryNotFound(id)
        }
        return entry
    }

    private static func decodeEntry(_ row: Row) throws -> HistoryEntry {
        let storedID: String = row[Column.id]
        guard let id = UUID(uuidString: storedID) else {
            throw HistoryStoreError.invalidStoredValue(column: Column.id, value: storedID)
        }

        let storedMode: String = row[Column.mode]
        guard let mode = HistoryDictationMode(rawValue: storedMode) else {
            throw HistoryStoreError.invalidStoredValue(column: Column.mode, value: storedMode)
        }

        let storedDeliveryStatus: String = row[Column.deliveryStatus]
        guard let deliveryStatus = HistoryDeliveryStatus(rawValue: storedDeliveryStatus) else {
            throw HistoryStoreError.invalidStoredValue(
                column: Column.deliveryStatus,
                value: storedDeliveryStatus
            )
        }

        let storedRefinementStatus: String = row[Column.refinementStatus]
        guard let refinementStatus = HistoryRefinementStatus(rawValue: storedRefinementStatus) else {
            throw HistoryStoreError.invalidStoredValue(
                column: Column.refinementStatus,
                value: storedRefinementStatus
            )
        }

        let candidatesJSON: String = row[Column.unrecognizedCommandCandidatesJSON]
        let candidates = try decodeCandidates(candidatesJSON)

        let storedSourceKind: String = row[Column.sourceKind]
        guard let sourceKind = HistorySourceKind(rawValue: storedSourceKind) else {
            throw HistoryStoreError.invalidStoredValue(
                column: Column.sourceKind,
                value: storedSourceKind
            )
        }

        return HistoryEntry(
            id: id,
            timestamp: row[Column.timestamp],
            rawText: row[Column.rawText],
            polishedText: row[Column.polishedText],
            destinationBundleIdentifier: row[Column.destinationBundleIdentifier],
            destinationDisplayName: row[Column.destinationDisplayName],
            mode: mode,
            deliveryStatus: deliveryStatus,
            refinementStatus: refinementStatus,
            asrLatency: row[Column.asrLatency],
            refinementLatency: row[Column.refinementLatency],
            totalLatency: row[Column.totalLatency],
            unrecognizedCommandCandidates: candidates,
            error: row[Column.error],
            polishRetryCount: row[Column.polishRetryCount],
            lastPolishAttemptAt: row[Column.lastPolishAttemptAt],
            asrSelection: row[Column.asrSelection],
            asrOutcome: row[Column.asrOutcome],
            refinerBackend: row[Column.refinerBackend],
            refinementOutcome: row[Column.refinementOutcome],
            validationFailureKind: row[Column.validationFailureKind],
            stopToPasteLatency: row[Column.stopToPasteLatency],
            sourceKind: sourceKind,
            remoteRoute: row[Column.remoteRoute],
            cleanupBackend: row[Column.cleanupBackend],
            userEditedText: row[Column.userEditedText],
            isPinned: row[Column.isPinned],
            entryRevision: row[Column.entryRevision],
            updatedAt: (row[Column.updatedAt] as Date?) ?? row[Column.timestamp]
        )
    }

    /// FTS tokenization intentionally handles ordinary words. Punctuation,
    /// quotes, and wildcard characters require literal substring semantics so
    /// they are handled by the escaped LIKE fallback below.
    private static func canRepresentInFTS(_ query: String) -> Bool {
        query.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    private static func escapeLikePattern(_ query: String) -> String {
        query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func encodeCandidates(_ candidates: [String]) throws -> String {
        let data = try JSONEncoder().encode(candidates)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeCandidates(_ json: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(json.utf8))
    }
}
