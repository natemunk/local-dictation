import Foundation
import Testing
@testable import LocalDictation

@Suite("Last dictation correction reference")
struct LastDictationCorrectionTests {
    @Test func eligibilityAndBusyGates() {
        var reference = LastDictationCorrection()
        let id = UUID()
        // All committed delivery/recovery paths share the same eligibility gate.
        reference.consider(id: id, deliveryCommitted: true, hasText: true, secure: false)
        #expect(reference.historyID == id)
        #expect(reference.canOpen(dictationActive: false, rewriteActive: false))
        #expect(!reference.canOpen(dictationActive: true, rewriteActive: false))
        #expect(!reference.canOpen(dictationActive: false, rewriteActive: true))
        reference.consider(id: UUID(), deliveryCommitted: false, hasText: true, secure: false)
        #expect(reference.historyID == id)
        reference.consider(id: UUID(), deliveryCommitted: true, hasText: true, secure: true)
        reference.consider(id: UUID(), deliveryCommitted: true, hasText: false, secure: false)
        reference.consider(id: UUID(), source: .iphonePWA, deliveryCommitted: true, hasText: true, secure: false)
        reference.consider(id: UUID(), source: .iphoneShortcut, deliveryCommitted: true, hasText: true, secure: false)
        #expect(reference.historyID == id)
        reference.invalidate(UUID())
        #expect(reference.historyID == id)
        reference.invalidate(id)
        #expect(reference.historyID == nil)
    }

    @Test func deletionAndRetentionNeverSubstituteAnotherEntry() async throws {
        let store = try HistoryStore.inMemory()
        var reference = LastDictationCorrection()
        let capture = HistoryRawCapture(timestamp: Date(timeIntervalSince1970: 1), rawText: "Synthetic recovery", mode: .clean)
        _ = try await store.saveRaw(capture)
        reference.consider(id: capture.id, deliveryCommitted: true, hasText: true, secure: false)
        #expect(reference.accepts(try await store.fetch(id: capture.id)))
        _ = try await store.pruneEntries(policy: HistoryRetentionPolicy(retentionDays: 90))
        #expect(!reference.accepts(try await store.fetch(id: capture.id)))
        let recent = HistoryRawCapture(rawText: "Synthetic recent", mode: .clean)
        _ = try await store.saveRaw(recent)
        #expect(!reference.accepts(try await store.fetch(id: recent.id)))
        reference.consider(id: recent.id, deliveryCommitted: true, hasText: true, secure: false)
        _ = try await store.deleteAll()
        #expect(!reference.accepts(try await store.fetch(id: recent.id)))
        reference.clear()
        #expect(reference.historyID == nil)
    }
}
