import Foundation

/// A request to stop one command that comes from its caller rather than
/// from a signal: the MCP client cancelled the tool call, or the call ran
/// out of its time budget. `CommandRouter.waitInterruptible` treats it like
/// a SIGINT for the command it is attached to (see
/// `CommandRouter.run(stoppingOn:_:)`). Any thread may set it, more than
/// once; the reason of highest precedence is kept.
final class StopRequest: @unchecked Sendable {
    /// Ordered by precedence, lowest first.
    enum Reason: Int, Comparable {
        /// The call ran past its time budget.
        case budgetExhausted
        /// The client cancelled the call (`notifications/cancelled`). It
        /// replaces an exhausted budget: the client no longer wants the
        /// result, so the call ends cancelled and the server sends no
        /// response to it.
        case cancelled

        static func < (a: Reason, b: Reason) -> Bool { a.rawValue < b.rawValue }
    }

    private let lock = NSLock()
    private var stoppedFor: Reason?

    func stop(_ reason: Reason) {
        lock.withLock {
            stoppedFor = max(stoppedFor ?? reason, reason)
        }
    }

    /// Why the command was asked to stop; nil while it may keep running.
    var reason: Reason? { lock.withLock { stoppedFor } }
}
