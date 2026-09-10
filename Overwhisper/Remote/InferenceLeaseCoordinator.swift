import Foundation

/// Keeps the shared final-ASR runtime single-owner without moving hotkey work
/// onto an actor. Desktop capture takes priority synchronously; remote work is
/// cancelled and must fully release its lease before desktop final ASR begins.
final class InferenceLeaseCoordinator: @unchecked Sendable {
    final class RemoteLease: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var cancellation: (@Sendable () -> Void)?
        private var wasCancelled = false

        func installCancellation(_ cancellation: @escaping @Sendable () -> Void) {
            lock.lock()
            if wasCancelled {
                lock.unlock()
                cancellation()
                return
            }
            self.cancellation = cancellation
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            wasCancelled = true
            let cancellation = cancellation
            lock.unlock()
            cancellation?()
        }
    }

    private let lock = NSLock()
    private var desktopActive = false
    private var remoteLease: RemoteLease?

    func beginDesktop() {
        lock.lock()
        desktopActive = true
        let lease = remoteLease
        lock.unlock()
        lease?.cancel()
    }

    func endDesktop() {
        lock.lock()
        desktopActive = false
        lock.unlock()
    }

    func tryBeginRemote(localRewriteBusy: Bool = false) -> RemoteLease? {
        lock.lock()
        defer { lock.unlock() }
        guard !localRewriteBusy, !desktopActive, remoteLease == nil else { return nil }
        let lease = RemoteLease()
        remoteLease = lease
        return lease
    }

    /// The caller must have completed source ASR before acquiring this lease.
    /// Unlike a phone request, instruction ASR may belong to the active desktop
    /// session. Keeping the same drain slot protects the next desktop ASR too.
    func tryBeginLocalInstructions() -> RemoteLease? {
        lock.lock()
        defer { lock.unlock() }
        guard remoteLease == nil else { return nil }
        let lease = RemoteLease()
        remoteLease = lease
        return lease
    }

    func endRemote(_ lease: RemoteLease) {
        lock.lock()
        if remoteLease?.id == lease.id {
            remoteLease = nil
        }
        lock.unlock()
    }

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return desktopActive || remoteLease != nil
    }

    func waitForRemoteRelease(timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while hasRemoteLease {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw IPhoneEndpointFailure(.remotePreempted)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private var hasRemoteLease: Bool {
        lock.lock()
        defer { lock.unlock() }
        return remoteLease != nil
    }
}
