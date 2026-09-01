import Foundation

/// Keeps history/menu Paste Again operations from interleaving pasteboard and
/// focus validation while an earlier operation is suspended.
@MainActor
final class SerializedPasteAgainQueue {
    private var tail: Task<Void, Never>?

    @discardableResult
    func enqueue(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let preceding = tail
        let task = Task { @MainActor in
            if let preceding { await preceding.value }
            guard !Task.isCancelled else { return }
            await operation()
        }
        tail = task
        return task
    }

    func cancelPending() {
        tail?.cancel()
        tail = nil
    }
}
