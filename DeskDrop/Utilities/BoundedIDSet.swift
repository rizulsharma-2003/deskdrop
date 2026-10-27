import Foundation

/// Remembers the most recent `capacity` IDs, forgetting the oldest first.
/// Used to refuse replayed or duplicated transfer offers.
struct BoundedIDSet: Sendable {
    private var order: [UUID] = []
    private var members: Set<UUID> = []
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    /// Returns false if `id` was already present.
    mutating func insert(_ id: UUID) -> Bool {
        guard members.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity {
            members.remove(order.removeFirst())
        }
        return true
    }

    func contains(_ id: UUID) -> Bool { members.contains(id) }
    var count: Int { members.count }
}
