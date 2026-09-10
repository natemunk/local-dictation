import Foundation

/// Revoking consent invalidates work already in flight, including work that
/// finishes after consent is enabled again. No transcript is held here.
final class HistoryPersistenceConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0

    func setEnabled(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard value != enabled else { return }
        enabled = value
        generation &+= 1
    }

    func authorization() -> HistoryPersistenceAuthorization? {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return nil }
        return HistoryPersistenceAuthorization(consent: self, generation: generation)
    }

    fileprivate func permits(_ expectedGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && generation == expectedGeneration
    }
}

struct HistoryPersistenceAuthorization: Sendable {
    fileprivate let consent: HistoryPersistenceConsent
    fileprivate let generation: UInt64

    var isCurrent: Bool { consent.permits(generation) }
}
