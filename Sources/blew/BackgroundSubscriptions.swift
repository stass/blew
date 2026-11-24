import Foundation

/// The REPL's background subscriptions (`sub -b`), at most one per
/// characteristic, each a task that streams its notifications. A new one
/// for a characteristic replaces the old, which is cancelled. A
/// subscription leaves the table when it is stopped or replaced, or when its
/// task ends by itself (count or duration reached, an error); a replaced
/// task that ends later does not remove its replacement. The tasks end off
/// the main thread, so the table is under a lock.
final class BackgroundSubscriptions: @unchecked Sendable {
    private struct Entry {
        let token: Int
        /// Nil only while `start` is between recording the entry and
        /// creating its task.
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var nextToken = 0
    private var entries: [String: Entry] = [:]

    /// Run `body` as the background subscription of `characteristic`,
    /// replacing (and cancelling) the one it has.
    func start(_ characteristic: String, _ body: @escaping @Sendable () async -> Void) {
        let (token, replaced) = lock.withLock { () -> (Int, Task<Void, Never>?) in
            nextToken += 1
            let replaced = entries[characteristic]?.task
            entries[characteristic] = Entry(token: nextToken, task: nil)
            return (nextToken, replaced)
        }
        replaced?.cancel()
        let task = Task {
            await body()
            self.finished(characteristic, token)
        }
        let recorded = lock.withLock { () -> Bool in
            guard entries[characteristic]?.token == token else { return false }
            entries[characteristic]?.task = task
            return true
        }
        // Stopped or replaced before its task was recorded (or already
        // finished, when cancelling does nothing): no one else can cancel it.
        if !recorded { task.cancel() }
    }

    /// Stop the subscription of `characteristic`; false when it has none.
    func stop(_ characteristic: String) -> Bool {
        guard let entry = lock.withLock({ entries.removeValue(forKey: characteristic) }) else { return false }
        entry.task?.cancel()
        return true
    }

    /// Stop every subscription; false when there was none.
    func stopAll() -> Bool {
        let all = lock.withLock { () -> [String: Entry] in
            defer { entries = [:] }
            return entries
        }
        for entry in all.values { entry.task?.cancel() }
        return !all.isEmpty
    }

    /// The characteristics with a running subscription, sorted.
    var characteristics: [String] {
        lock.withLock { entries.keys.sorted() }
    }

    private func finished(_ characteristic: String, _ token: Int) {
        lock.withLock {
            if entries[characteristic]?.token == token { entries[characteristic] = nil }
        }
    }
}
