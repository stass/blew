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
/// `CommandRouter.run(stoppingOn:_:)`.
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
    /// budget, in seconds, counts from when `work` starts.
    func run<T>(budget: TimeInterval, _ work: @escaping (StopRequest) -> T) async -> Outcome<T> {
        let stop = StopRequest()
        let box = ResultBox<T>()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                queue.async { [timers] in
                    // Declared first, so it runs last: the result is stored
                    // and the timer cancelled before the caller resumes.
                    defer { done.resume() }
                    guard stop.reason == nil else { return }
                    let budgetTimer = DispatchWorkItem { stop.stop(.budgetExhausted) }
                    timers.asyncAfter(deadline: .now() + budget, execute: budgetTimer)
                    defer { budgetTimer.cancel() }
                    box.value = work(stop)
                }
            }
        } onCancel: {
            stop.stop(.cancelled)
        }
        switch (box.value, stop.reason) {
        case (let value?, nil): return .finished(value)
        case (let value?, .budgetExhausted?): return .budgetExhausted(value)
        // No value: the call was cancelled before it started.
        case (_, .cancelled?), (nil, _): return .cancelled
        }
    }
}

/// Carries a call's result from the queue's thread to the awaiting Task.
/// Written once, before the continuation resumes, and read after it.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
#endif
