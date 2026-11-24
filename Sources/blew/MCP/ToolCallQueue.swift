#if MCP_ENABLED
import Foundation

/// Runs MCP tool calls one at a time, in the order they reach the queue.
///
/// The swift-sdk handles each request in its own Task, but every tool call
/// drives the one `CommandRouter` and the one BLE connection, whose waits
/// hold a single operation each. The queue gives them a single user: a
/// call starts only when the one before it has returned. Two requests a
/// client sends without waiting for the first reply reach the queue in
/// either order, because their Tasks race until they are enqueued.
///
/// The router's commands are synchronous and block their thread on
/// semaphores, so they run on the queue's own serial dispatch queue, never
/// on a thread of Swift's cooperative pool. The calling Task suspends on a
/// continuation until its work has returned.
///
/// Each call carries a `StopRequest`. Cancelling the calling Task (the
/// swift-sdk does so on `notifications/cancelled`) sets it to `.cancelled`;
/// a call that waits its turn when cancelled does not start. Once a call
/// starts, its budget counts down, and when it runs out the request is set
/// to `.budgetExhausted`. The work sees the request through
/// `CommandRouter.run(stoppingOn:_:)`. The outcome is decided on the queue
/// when the work returns, so a cancellation that arrives later neither
/// changes it nor reorders it against the calls after it.
final class ToolCallQueue: @unchecked Sendable {
    /// What became of one call.
    enum Outcome<T> {
        /// The work returned without being asked to stop.
        case finished(T)
        /// The client cancelled the call, before or while it ran.
        case cancelled
        /// The budget ran out while the work ran; this is what it returned.
        case budgetExhausted(T)
    }

    private let queue = DispatchQueue(label: "blew.mcp.calls")
    private let timers = DispatchQueue(label: "blew.mcp.budgets")

    /// Run `work` after every call submitted before it has returned. The
    /// budget, in seconds, counts from when `work` starts. The outcome's
    /// value is what `work` returned: `run(budget:_:settle:)` with a
    /// `settle` that changes nothing.
    func run<T>(budget: TimeInterval, _ work: @escaping (StopRequest) -> T) async -> Outcome<T> {
        await run(budget: budget, work) { value, _ in value }
    }

    /// Run `work` as `run(budget:_:)` does, then `settle`, on the queue,
    /// before the next call starts: with what `work` returned and whether
    /// the call has been cancelled. That is where the call's outcome is
    /// decided: a cancellation that arrives once `work` has returned does
    /// not change it. What `settle` returns is the outcome's value; a
    /// cancelled call's is dropped. `settle` does not run for a call
    /// cancelled before it started.
    func run<T, R>(
        budget: TimeInterval,
        _ work: @escaping (StopRequest) -> T,
        settle: @escaping (_ value: T, _ cancelled: Bool) -> R
    ) async -> Outcome<R> {
        let stop = StopRequest()
        let box = ResultBox<Outcome<R>>()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                queue.async { [timers] in
                    // Declared first, so it runs last: the outcome is stored
                    // before the caller resumes.
                    defer { done.resume() }
                    guard stop.reason == nil else { return }
                    let budgetTimer = DispatchWorkItem { stop.stop(.budgetExhausted) }
                    timers.asyncAfter(deadline: .now() + budget, execute: budgetTimer)
                    let value = work(stop)
                    budgetTimer.cancel()
                    let reason = stop.reason
                    let settled = settle(value, reason == .cancelled)
                    switch reason {
                    case nil: box.value = .finished(settled)
                    case .budgetExhausted?: box.value = .budgetExhausted(settled)
                    case .cancelled?: box.value = .cancelled
                    }
                }
            }
        } onCancel: {
            stop.stop(.cancelled)
        }
        // No outcome: the call was cancelled before it started.
        return box.value ?? .cancelled
    }
}

/// Carries a call's outcome from the queue's thread to the awaiting Task.
/// Written once, before the continuation resumes, and read after it.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
#endif
