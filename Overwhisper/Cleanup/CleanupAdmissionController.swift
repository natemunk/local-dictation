import Foundation

enum CleanupAdmissionError: Error, Sendable { case busy }

struct CleanupAdmissionSnapshot: Equatable, Sendable {
    enum State: String, Sendable { case idle, running, draining }
    let state: State
    let elapsedSeconds: Double
    static let idle = Self(state: .idle, elapsedSeconds: 0)
}

/// AppDelegate owns one instance across all optional desktop/phone refiners.
/// Cancellation releases the caller, not the slot: only provider exit does that.
final class CleanupAdmissionController: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: UUID?
    private var started: TimeInterval = 0
    private var draining = false

    func acquire() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil else { throw CleanupAdmissionError.busy }
        let id = UUID()
        owner = id
        started = ProcessInfo.processInfo.systemUptime
        draining = false
        return id
    }

    func markDraining(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owner == id { draining = true }
    }

    func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owner == id { owner = nil; draining = false }
    }

    func snapshot() -> CleanupAdmissionSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard owner != nil else { return .idle }
        return .init(state: draining ? .draining : .running,
                     elapsedSeconds: max(0, ProcessInfo.processInfo.systemUptime - started))
    }
}

/// Synchronous arbitration also covers cancellation before continuation/task
/// installation. Never resume a continuation or cancel a task under the lock.
private final class CleanupDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    var isPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return result == nil
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        let result = result
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }

    func install(worker: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        if !finished { self.worker = worker; self.timer = timer }
        lock.unlock()
        if finished { worker.cancel(); timer.cancel() }
    }

    @discardableResult
    func resolve(_ result: Result<Value, Error>, cancelWorker: Bool) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = continuation
        let worker = worker
        let timer = timer
        self.continuation = nil; self.worker = nil; self.timer = nil
        lock.unlock()
        if cancelWorker { worker?.cancel() }
        timer?.cancel()
        continuation?.resume(with: result)
        return true
    }
}

enum CleanupDeadline {
    static let standard: Duration = .seconds(2)

    static func run<Value: Sendable>(
        for duration: Duration = standard,
        admission: CleanupAdmissionController = CleanupAdmissionController(),
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let owner = try admission.acquire()
        let deadline = ContinuousClock.now.advanced(by: duration)
        let race = CleanupDeadlineRace<Value>()
        let priority = Task.currentPriority
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let worker = Task.detached(priority: priority) {
                    guard race.isPending else { admission.release(owner); return }
                    let result: Result<Value, Error>
                    do {
                        try Task.checkCancellation()
                        let value = try await operation()
                        try Task.checkCancellation()
                        result = .success(value)
                    } catch { result = .failure(error) }
                    admission.release(owner)
                    race.resolve(result, cancelWorker: false)
                }
                let timer = Task.detached(priority: priority) {
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    admission.markDraining(owner)
                    race.resolve(.failure(CleanupDeadlineError.exceeded), cancelWorker: true)
                }
                race.install(worker: worker, timer: timer)
            }
        } onCancel: {
            admission.markDraining(owner)
            race.resolve(.failure(CancellationError()), cancelWorker: true)
        }
        try Task.checkCancellation()
        return value
    }
}
