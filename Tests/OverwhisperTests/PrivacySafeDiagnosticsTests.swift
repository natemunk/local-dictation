import Foundation
import Testing
@testable import LocalDictation

@Suite("Privacy-safe diagnostics", .serialized)
struct PrivacySafeDiagnosticsTests {
    @Test("diagnostic fields are a closed allowlist and content-bearing state never leaks")
    @MainActor
    func allowlistedFieldsExcludeSensitiveState() throws {
        let suiteName = "PrivacySafeDiagnosticsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let transcriptSentinel = "SENSITIVE_TRANSCRIPT_7F2A"
        let clipboardSentinel = "SENSITIVE_CLIPBOARD_91C4"
        let audioSentinel = "SENSITIVE_AUDIO_FILE_42D8.wav"
        let browserSentinel = "https://private.example.test/account"
        let focusedFieldSentinel = "SENSITIVE_FOCUSED_FIELD_A30E"
        let apiKeySentinel = "sk-sensitive-diagnostic-key"

        let state = AppState(preferences: defaults)
        state.microphonePermissionGranted = true
        state.inputMonitoringGranted = true
        state.accessibilityGranted = true
        state.hotkeyMonitoringActive = true
        state.engineReady = true
        state.lastTranscription = transcriptSentinel
        state.liveTranscript = LiveTranscript(
            finalized: transcriptSentinel,
            volatile: focusedFieldSentinel
        )
        state.raycastVocabularyImportText = clipboardSentinel
        state.customVocabulary = focusedFieldSentinel
        state.selectedInputDeviceUID = audioSentinel
        state.refinerAPIKey = apiKeySentinel
        state.lastError = browserSentinel
        state.hotkeyMonitoringError = browserSentinel
        state.configurationDiagnostic = nil
        state.configurationNotices = [browserSentinel]
        state.recordTapDiagnostic(
            disableCount: 2,
            rebuildCount: 1,
            lastReason: browserSentinel
        )
        state.recordModelDiagnostic(
            EngineStatus(
                selection: .parakeetV2,
                phase: .failed,
                preparationGeneration: 7,
                ownedPath: browserSentinel,
                progress: nil,
                lastError: browserSentinel
            )
        )
        state.recordConfigurationDiagnostic(
            generation: 9,
            applied: false,
            historyRetentionDays: 45
        )
        state.recordEOUDiagnostic(.streaming)
        state.updateHistoryDiagnosticHealth(
            HistoryStoreHealth(
                journalMode: "wal",
                appliedMigrationIdentifiers: HistoryStore.expectedMigrationIdentifiers
                    + [browserSentinel],
                retentionPolicy: HistoryRetentionPolicy(retentionDays: 45),
                entryCount: 3,
                pendingEntryCount: 1,
                lastDeliveryStatus: .historyOnly,
                integrityCheckPassed: true
            )
        )
        state.recordInsertionDiagnostic(.clipboardOnly(reason: clipboardSentinel))

        let snapshot = PrivacySafeDiagnosticSnapshot(appState: state)
        let fieldNames = snapshot.fields.map(\.name)
        #expect(fieldNames == DiagnosticFieldName.allCases)
        #expect(Set(fieldNames).count == fieldNames.count)

        let forbiddenFieldNameFragments = [
            "transcript", "audio", "browser", "url", "hostname", "focused",
            "clipboard_contents", "api_key", "destination",
        ]
        for fieldName in fieldNames.map(\.rawValue) {
            for forbidden in forbiddenFieldNameFragments {
                #expect(!fieldName.contains(forbidden))
            }
        }

        let encoded = try JSONEncoder().encode(snapshot)
        let json = try #require(String(data: encoded, encoding: .utf8))
        let exported = snapshot.renderedReport + "\n" + json
        for sentinel in [
            transcriptSentinel,
            clipboardSentinel,
            audioSentinel,
            browserSentinel,
            focusedFieldSentinel,
            apiKeySentinel,
        ] {
            #expect(!exported.contains(sentinel))
        }
        #expect(snapshot.tap.disableCount == 2)
        #expect(snapshot.tap.rebuildCount == 1)
        #expect(snapshot.tap.lastReason == .other)
        #expect(snapshot.model.preparationGeneration == 7)
        #expect(
            snapshot.model.ownedPath
                == "~/Library/Application Support/LocalDictation/Models/v1/parakeet-v2/fluidaudio-0.14.3/current"
        )
        #expect(snapshot.model.lastFailure == .initialization)
        #expect(snapshot.configuration.usingLastKnownGood)
        #expect(snapshot.history.retentionDays == 45)
        #expect(snapshot.insertion.lastFailure == .other)
    }

    @Test("insertion failure diagnostics reduce reason text to safe categories")
    func insertionFailureCategories() {
        #expect(
            InsertionDiagnosticFailureKind(
                .historyOnly(reason: "Secure fields cannot receive dictation or history paste")
            ) == .secureDestination
        )
        #expect(
            InsertionDiagnosticFailureKind(
                .clipboardOnly(reason: "The original destination field is no longer focused")
            ) == .destinationChanged
        )
        #expect(
            InsertionDiagnosticFailureKind(
                .historyOnly(reason: "The clipboard changed before paste")
            ) == .clipboardChanged
        )
        #expect(
            InsertionDiagnosticFailureKind(
                .historyOnly(reason: "SENSITIVE_UNRECOGNIZED_REASON")
            ) == .other
        )
    }

    @Test("history health rejects structural and integrity problems")
    func historyHealthModel() {
        let expected = HistoryStore.expectedMigrationIdentifiers
        let healthy = makeHealth(
            migrations: expected,
            entryCount: 4,
            pendingEntryCount: 1,
            lastDeliveryStatus: .pasteEventSent
        )
        #expect(healthy.isOperational(expectedMigrationIdentifiers: expected))

        #expect(!makeHealth(
            journalMode: "delete",
            migrations: expected,
            entryCount: 1,
            lastDeliveryStatus: .pasteEventSent
        ).isOperational(expectedMigrationIdentifiers: expected))
        #expect(!makeHealth(
            migrations: Array(expected.dropLast()),
            entryCount: 1,
            lastDeliveryStatus: .pasteEventSent
        ).isOperational(expectedMigrationIdentifiers: expected))
        #expect(!makeHealth(
            migrations: expected,
            entryCount: 1,
            lastDeliveryStatus: .pasteEventSent,
            integrityCheckPassed: false
        ).isOperational(expectedMigrationIdentifiers: expected))
        #expect(!makeHealth(
            migrations: expected,
            entryCount: 1,
            pendingEntryCount: 2,
            lastDeliveryStatus: .pending
        ).isOperational(expectedMigrationIdentifiers: expected))
        #expect(!makeHealth(
            migrations: expected,
            entryCount: 1,
            lastDeliveryStatus: nil
        ).isOperational(expectedMigrationIdentifiers: expected))
    }

    @Test("read-only history health reports counts and outcome without row content")
    func readOnlyHistoryHealth() async throws {
        let directory = try makeDiagnosticsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("history.sqlite")
        let store = try HistoryStore(databaseURL: databaseURL)
        let entry = try await store.saveRaw(
            HistoryRawCapture(
                rawText: "SENSITIVE_HISTORY_ROW_593B",
                destination: HistoryDestination(
                    bundleIdentifier: "private.bundle.identifier",
                    displayName: "Private Destination"
                ),
                mode: .literal
            )
        )
        _ = try await store.updateDelivery(
            id: entry.id,
            with: HistoryDeliveryUpdate(
                status: .clipboardOnly,
                deliveredText: "SENSITIVE_DELIVERED_ROW_0F17",
                error: "SENSITIVE_HISTORY_ERROR_C888"
            )
        )

        let liveHealth = try await store.health()
        let readOnlyHealth = try HistoryStore.readOnlyHealth(databaseURL: databaseURL)

        #expect(readOnlyHealth == liveHealth)
        #expect(readOnlyHealth.entryCount == 1)
        #expect(readOnlyHealth.pendingEntryCount == 0)
        #expect(readOnlyHealth.lastDeliveryStatus == .clipboardOnly)
        #expect(readOnlyHealth.integrityCheckPassed)
        #expect(readOnlyHealth.isOperational(
            expectedMigrationIdentifiers: HistoryStore.expectedMigrationIdentifiers
        ))
    }

    private func makeHealth(
        journalMode: String = "wal",
        migrations: [String],
        entryCount: Int,
        pendingEntryCount: Int = 0,
        lastDeliveryStatus: HistoryDeliveryStatus?,
        integrityCheckPassed: Bool = true
    ) -> HistoryStoreHealth {
        HistoryStoreHealth(
            journalMode: journalMode,
            appliedMigrationIdentifiers: migrations,
            retentionPolicy: .default,
            entryCount: entryCount,
            pendingEntryCount: pendingEntryCount,
            lastDeliveryStatus: lastDeliveryStatus,
            integrityCheckPassed: integrityCheckPassed
        )
    }

    private func makeDiagnosticsTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
