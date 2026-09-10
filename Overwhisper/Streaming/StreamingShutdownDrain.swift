import Foundation

/// Actor-owned handle for one shutdown operation. Repeated cancellation must
/// await this same task, including the final reset, rather than return early
/// just because the session ID has already been cleared.
struct StreamingShutdownDrain {
    private(set) var task: Task<Void, Never>?

    mutating func begin(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        if let task { return task }
        let created = Task { await operation() }
        task = created
        return created
    }

    /// Only the invocation that began shutdown clears it, after task.value.
    mutating func clear() {
        task = nil
    }
}
