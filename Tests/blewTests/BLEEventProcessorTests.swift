import XCTest
@testable import BLEManager

/// The event processor without CoreBluetooth: events are handed to it
/// directly, as the delegate would queue them.
final class BLEEventProcessorTests: XCTestCase {
    private let disconnect = BLEEvent.didDisconnect(peripheralId: UUID(), error: nil)

    /// A notification stream registered the way BLEManager.subscribe does:
    /// its termination handler deregisters it, which takes the processor's
    /// lock. `finished` is signalled once the stream has ended.
    private func registerStream(_ processor: BLEEventProcessor, finished: DispatchSemaphore) -> AsyncStream<Data> {
        AsyncStream<Data> { continuation in
            processor.setNotificationContinuation(forChar: "TX", continuation)
            continuation.onTermination = { _ in
                processor.setNotificationContinuation(forChar: "TX", nil)
                finished.signal()
            }
        }
    }

    /// A disconnect finishes the notification streams and runs the
    /// disconnect callbacks; both re-enter the processor, so dispatching it
    /// must not hold the processor's lock while they run.
    func testDisconnectEndsStreamsAndCallsBackWithoutDeadlock() {
        let processor = BLEEventProcessor(eventQueue: BLEEventQueue())
        let finished = DispatchSemaphore(value: 0)
        let stream = registerStream(processor, finished: finished)
        let calledBack = DispatchSemaphore(value: 0)
        processor.onDisconnect { _ in
            processor.setWriteReadyContinuation(nil)
            calledBack.signal()
        }

        let dispatched = DispatchSemaphore(value: 0)
        Thread {
            processor.dispatch(self.disconnect)
            dispatched.signal()
        }.start()

        XCTAssertEqual(dispatched.wait(timeout: .now() + 2), .success, "dispatching a disconnect deadlocked")
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success, "the notification stream did not end")
        XCTAssertEqual(calledBack.wait(timeout: .now() + 1), .success, "the disconnect callback did not run")
        withExtendedLifetime(stream) {}
    }

    /// handleEvent only updates the registrations; the stream ends when the
    /// caller runs the returned effects, and the processor is unlocked by then.
    func testHandleEventDefersEffectsToTheCaller() {
        let processor = BLEEventProcessor(eventQueue: BLEEventQueue())
        let finished = DispatchSemaphore(value: 0)
        let stream = registerStream(processor, finished: finished)

        let effects = processor.handleEvent(disconnect)
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut, "the stream ended under the lock")
        effects.forEach { $0() }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        withExtendedLifetime(stream) {}
    }
}
