import Foundation
import Testing
@testable import LocalDictation

/// Test handshake: provider entry is distinct from acquiring its admission slot.
/// Intentionally ignores task cancellation until the test explicitly releases it.
final class CancellationIgnoringCleanupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var released = false

    var hasStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return entered
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return released
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            entered = true
            let released = released
            if !released { self.continuation = continuation }
            lock.unlock()
            if released { continuation.resume() }
        }
    }

    func open() {
        lock.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private struct DelayedAppleAdapter: AppleFoundationModelAdapter {
    let gate: CancellationIgnoringCleanupGate
    func availability() -> AppleFoundationModelAvailability { .available }
    func generate(transcript: String, staticRules: String) async throws -> String {
        await gate.wait()
        return transcript
    }
}

@Suite("Cleanup deadline admission")
struct CleanupAdmissionTests {
    @Test func providerInheritsCallerPriority() async throws {
        let task = Task(priority: .high) {
            let expected = Task.currentPriority
            let actual = try await CleanupDeadline.run(admission: CleanupAdmissionController()) {
                Task.currentPriority
            }
            #expect(actual >= expected)
        }
        try await task.value
    }
    @Test func uncooperativeTimeoutHoldsSlotAndRecovers() async throws {
        let admission = CleanupAdmissionController()
        let gate = CancellationIgnoringCleanupGate()
        // Rescue only bounds a broken implementation that waits for provider
        // exit. Passing requires the caller to return while this gate is closed.
        let rescue = DispatchWorkItem { gate.open() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: rescue)
        defer { rescue.cancel(); gate.open() }
        do {
            _ = try await CleanupDeadline.run(for: .milliseconds(100), admission: admission) {
                await gate.wait()
                return "late"
            }
            Issue.record("Deadline should win")
        } catch is CleanupDeadlineError {} catch { Issue.record("Unexpected error") }
        // Reproduce delayed caller resumption without releasing the provider.
        // Correctness must not depend on the old 200 ms assertion window.
        try await Task.sleep(for: .milliseconds(300))
        #expect(gate.hasStarted)
        #expect(!gate.isOpen)
        #expect(admission.snapshot().state == .draining)
        do {
            _ = try await CleanupDeadline.run(admission: admission) { "must not run" }
            Issue.record("Occupied admission must reject")
        } catch is CleanupAdmissionError {} catch { Issue.record("Unexpected error") }
        gate.open()
        let releasedBy = ContinuousClock.now.advanced(by: .seconds(5))
        while admission.snapshot().state != .idle && ContinuousClock.now < releasedBy {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(admission.snapshot().state == .idle)
        #expect(try await CleanupDeadline.run(admission: admission) { "ready" } == "ready")
    }

    @Test func freshRefinersShareAdmissionAndLabelFallback() async throws {
        let admission = CleanupAdmissionController()
        let gate = CancellationIgnoringCleanupGate()
        let rescue = DispatchWorkItem { gate.open() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: rescue)
        defer { rescue.cancel(); gate.open() }
        func pipeline() -> CleanupPipeline {
            CleanupPipeline(refiner: AppleFoundationRefiner(
                adapter: DelayedAppleAdapter(gate: gate), deadline: .milliseconds(100),
                admission: admission, platformSupportsFoundationModels: { true }))
        }
        let first = try await pipeline().process("We should ship.", mode: .clean)
        #expect(first.fallbackReasonLabel == "deadline_exceeded")
        #expect(gate.hasStarted)
        #expect(!gate.isOpen)
        let second = try await pipeline().process("We should ship.", mode: .clean)
        #expect(second.fallbackReasonLabel == "admission_busy")
        #expect(second.text == "We should ship.")
        gate.open()
        let releasedBy = ContinuousClock.now.advanced(by: .seconds(5))
        while admission.snapshot().state != .idle && ContinuousClock.now < releasedBy {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(admission.snapshot().state == .idle)
    }

    @Test func callerCancellationReleasesRemoteLeaseButNotCleanupSlot() async throws {
        let admission = CleanupAdmissionController()
        let gate = CancellationIgnoringCleanupGate()
        defer { gate.open() }
        let leases = InferenceLeaseCoordinator()
        let lease = try #require(leases.tryBeginRemote())
        let work = Task {
            defer { leases.endRemote(lease) }
            return try await CleanupDeadline.run(admission: admission) {
                await gate.wait()
                return "late"
            }
        }
        defer { work.cancel() }
        lease.installCancellation { work.cancel() }
        let preparationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.hasStarted && ContinuousClock.now < preparationDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(gate.hasStarted)
        leases.beginDesktop()
        do { _ = try await work.value; Issue.record("Expected cancellation") }
        catch is CancellationError {} catch { Issue.record("Unexpected error") }
        try await leases.waitForRemoteRelease(timeout: .milliseconds(50))
        #expect(admission.snapshot().state == .draining)
        leases.endDesktop()
        gate.open()
        let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while admission.snapshot().state != .idle && ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(admission.snapshot().state == .idle)
    }

    @Test func preCancelledCallDoesNotAcquire() async {
        let admission = CleanupAdmissionController()
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CleanupDeadline.run(admission: admission) { "unexpected" }
        }
        do { _ = try await work.value; Issue.record("Expected cancellation") }
        catch is CancellationError {} catch { Issue.record("Unexpected error") }
        #expect(admission.snapshot() == .idle)
    }

    @Test func pipelineChecksTaskCancellationNotOnlyErrorType() async {
        struct CancelledURLRefiner: TextRefiner {
            func refine(_ input: TextRefinementInput) async throws -> String {
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.cancelled)
            }
        }
        let task = Task {
            try await CleanupPipeline(refiner: CancelledURLRefiner()).process("Hello.", mode: .clean)
        }
        do { _ = try await task.value; Issue.record("Cancellation must not become fallback") }
        catch is CancellationError {} catch { Issue.record("Unexpected error") }
    }

    @Test func completionDeadlineRacesReleaseExactlyOnce() async throws {
        enum ProviderFailure: Error { case failed }
        let admission = CleanupAdmissionController()
        for index in 0..<100 {
            do {
                _ = try await CleanupDeadline.run(for: .nanoseconds(1), admission: admission) {
                    if index.isMultiple(of: 2) { throw ProviderFailure.failed }
                    return 1
                }
            } catch is CleanupDeadlineError {} catch is CleanupAdmissionError {} catch is ProviderFailure {}
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(admission.snapshot().state == .idle)
    }
}
