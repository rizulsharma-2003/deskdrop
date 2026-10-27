import Foundation

/// Keyed, cancellable timers that run on the main actor.
///
/// Scheduling a key that is already pending replaces the earlier timer, so callers
/// never accumulate duplicate timeouts for the same peer or transfer.
@MainActor
final class ScheduledTasks<Key: Hashable> {
    private var tasks: [Key: Task<Void, Never>] = [:]

    func schedule(_ key: Key, after delay: Duration, action: @escaping @MainActor @Sendable () -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.tasks[key] = nil
            action()
        }
    }

    func cancel(_ key: Key) {
        tasks.removeValue(forKey: key)?.cancel()
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    func isScheduled(_ key: Key) -> Bool { tasks[key] != nil }
}
