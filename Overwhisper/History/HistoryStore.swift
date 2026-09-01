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
    static let expectedMigrationIdentifiers = [
        schemaMigrationIdentifier,
        searchMigrationIdentifier,
        searchBundleMigrationIdentifier,
        metadataMigrationIdentifier,
    ]

    private static let tableName = "dictation_history"
    private static let searchTableName = "dictation_history_fts"

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
        self.database = database
        try Self.makeMigrator().migrate(database)
    }

    private init(database: DatabaseQueue) throws {
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
                        \(Column.asrOutcome)
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                ]
            )

            return try Self.requireEntry(capture.id, in: db)
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
                    SET \(Column.polishedText) = ?,
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
                    SET \(Column.polishedText) = COALESCE(?, \(Column.polishedText)),
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
                    SET \(Column.refinementStatus) = ?,
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
                    SET \(Column.refinementStatus) = ?,
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
                    HistoryRefinementStatus.retrying.rawValue,
                    HistoryDeliveryStatus.failed.rawValue,
                    HistoryDeliveryStatus.pending.rawValue,
                    retryCount,
                    startedAt,
                    id.uuidString.lowercased(),
                ]
            )

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
            return count
        }
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
                sql: "SELECT COUNT(*) FROM \(Self.tableName) WHERE \(Column.timestamp) < ?",
                arguments: [cutoff]
            ) ?? 0
            try db.execute(
                sql: "DELETE FROM \(Self.tableName) WHERE \(Column.timestamp) < ?",
                arguments: [cutoff]
            )
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

    // MARK: - Migration and schema diagnostics

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
            stopToPasteLatency: row[Column.stopToPasteLatency]
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
