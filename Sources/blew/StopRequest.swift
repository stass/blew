import Foundation

/// A request to stop one command that comes from its caller rather than
/// from a signal: the MCP client cancelled the tool call, or the call ran
/// out of its time budget. `CommandRouter.waitInterruptible` treats it like
/// a SIGINT for the command it is attached to (see
/// `CommandRouter.run(stoppingOn:_:)`). Any thread may set it; the first
/// reason set is kept.
final class StopRequest: @unchecked Sendable {
    enum Reason: Equatable {
        /// The client cancelled the call (`notifications/cancelled`).
        case cancelled
        /// The call ran past its time budget.
        case budgetExhausted
    }

    private let lock = NSLock()
    private var stoppedFor: Reason?

    func stop(_ reason: Reason) {
        lock.withLock {
            if stoppedFor == nil { stoppedFor = reason }
        }
    }

    /// Why the command was asked to stop; nil while it may keep running.
    var reason: Reason? { lock.withLock { stoppedFor } }
}
