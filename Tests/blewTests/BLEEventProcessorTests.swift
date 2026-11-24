import XCTest
import CoreBluetooth
@testable import BLEManager

/// The event processor without CoreBluetooth: events are handed to it
/// directly, as the delegate would queue them.
final class BLEEventProcessorTests: XCTestCase {
    private let deviceA = UUID()
    private let deviceB = UUID()

    /// A one-shot wait registered the way BLECentral registers one, run in a
    /// task. The initializer returns once the continuation is registered.
    private final class Wait<T: Sendable>: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<T, Error>?

        init(_ register: @escaping @Sendable (CheckedContinuation<T, Error>) -> Void) {
            let registered = DispatchSemaphore(value: 0)
            Task {
                let result: Result<T, Error>
                do {
                    result = .success(try await withCheckedThrowingContinuation { cont in
                        register(cont)
                        registered.signal()
                    })
                } catch {
                    result = .failure(error)
                }
                self.lock.withLock { self.result = result }
                self.done.signal()
            }
            registered.wait()
        }

        /// The outcome, or nil when the wait is still pending after `timeout`.
        func outcome(timeout: TimeInterval = 1) -> Result<T, Error>? {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
            done.signal()
            return lock.withLock { result }
        }
    }

    /// A processor connected to `peripheral` the way BLECentral connects.
    private func connected(to peripheral: UUID) -> BLEEventProcessor {
        let processor = BLEEventProcessor(eventQueue: BLEEventQueue())
        let connect = Wait<Void> { processor.beginConnect(to: peripheral, $0) }
        processor.dispatch(.didConnect(peripheralId: peripheral))
        if case .success = connect.outcome() {} else { XCTFail("the connect did not complete") }
        return processor
    }

    /// Dispatch `event` and report whether the processor ignored it: it
    /// produced no effects.
    private func ignores(_ processor: BLEEventProcessor, _ event: BLEEvent) -> Bool {
        let effects = processor.handleEvent(event)
        effects.forEach { $0() }
        return effects.isEmpty
    }

    /// A notification stream registered the way BLEManager.subscribe does:
    /// its termination handler deregisters it, which takes the processor's
    /// lock. `finished` is signalled once the stream has ended.
    private func registerStream(_ processor: BLEEventProcessor, finished: DispatchSemaphore) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream<Data, Error> { continuation in
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
        let processor = connected(to: deviceB)
        let finished = DispatchSemaphore(value: 0)
        let stream = registerStream(processor, finished: finished)
        let calledBack = DispatchSemaphore(value: 0)
        processor.onDisconnect { _ in
            processor.setWriteReadyContinuation(nil)
            calledBack.signal()
        }

        let dispatched = DispatchSemaphore(value: 0)
        let disconnect = BLEEvent.didDisconnect(peripheralId: deviceB, error: nil)
        Thread {
            processor.dispatch(disconnect)
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
        let processor = connected(to: deviceB)
        let finished = DispatchSemaphore(value: 0)
        let stream = registerStream(processor, finished: finished)

        let effects = processor.handleEvent(.didDisconnect(peripheralId: deviceB, error: nil))
        XCTAssertEqual(effects.count, 1)
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut, "the stream ended under the lock")
        effects.forEach { $0() }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        withExtendedLifetime(stream) {}
    }

    /// A connect completes or fails only on its own peripheral's events.
    func testConnectIgnoresAnotherPeripheralsEvents() {
        let processor = BLEEventProcessor(eventQueue: BLEEventQueue())
        let connect = Wait<Void> { processor.beginConnect(to: self.deviceB, $0) }

        XCTAssertTrue(ignores(processor, .didConnect(peripheralId: deviceA)))
        XCTAssertTrue(ignores(processor, .didFailToConnect(peripheralId: deviceA, error: "refused")))
        XCTAssertTrue(ignores(processor, .didDisconnect(peripheralId: deviceA, error: nil)))
        XCTAssertNil(connect.outcome(timeout: 0.1), "another peripheral's event ended the connect")

        processor.dispatch(.didFailToConnect(peripheralId: deviceB, error: "refused"))
        guard case .failure(BLEError.connectionFailed) = connect.outcome() else {
            return XCTFail("the connect did not fail on its peripheral's didFailToConnect")
        }
    }

    /// `connect A` is cancelled (it timed out), `connect B` starts, and A
    /// comes into range: A's late events must not complete or fail B's connect.
    func testCancelledConnectsLateEventsDoNotReachTheNextConnect() {
        let processor = BLEEventProcessor(eventQueue: BLEEventQueue())
        let connectA = Wait<Void> { processor.beginConnect(to: self.deviceA, $0) }
        processor.cancelConnect()
        guard case .failure(is CancellationError) = connectA.outcome() else {
            return XCTFail("the cancelled connect did not end with CancellationError")
        }

        let connectB = Wait<Void> { processor.beginConnect(to: self.deviceB, $0) }
        XCTAssertTrue(ignores(processor, .didConnect(peripheralId: deviceA)))
        XCTAssertTrue(ignores(processor, .didDisconnect(peripheralId: deviceA, error: nil)))
        XCTAssertNil(connectB.outcome(timeout: 0.1), "A's late event ended B's connect")

        processor.dispatch(.didConnect(peripheralId: deviceB))
        guard case .success = connectB.outcome() else {
            return XCTFail("B's connect did not complete on B's didConnect")
        }
    }

    /// A cancelled connect stops serving its peripheral: a late didConnect
    /// does not make the processor route that peripheral's events.
    func testCancelledConnectStopsServingItsPeripheral() {
        let processor = BLEEventProcessor(eventQueue: BLEEventQueue())
        let connect = Wait<Void> { processor.beginConnect(to: self.deviceA, $0) }
        processor.cancelConnect()
        _ = connect.outcome()
        processor.onDisconnect { _ in }

        XCTAssertTrue(ignores(processor, .didConnect(peripheralId: deviceA)))
        XCTAssertNil(processor.connectedPeripheralId, "a cancelled connect's late didConnect connected it")
        XCTAssertTrue(ignores(processor, .didDisconnect(peripheralId: deviceA, error: nil)),
                      "the cancelled peripheral's disconnect still ran the disconnect callbacks")
    }

    /// The connected peripheral is the processor's: none while a connect
    /// waits, the peripheral once it connected, none after it disconnected.
    /// A cancel that comes after the connect completed leaves it connected.
    func testConnectedPeripheralFollowsTheLink() {
        let processor = BLEEventProcessor(eventQueue: BLEEventQueue())
        let connect = Wait<Void> { processor.beginConnect(to: self.deviceB, $0) }
        XCTAssertNil(processor.connectedPeripheralId)
        XCTAssertTrue(processor.isConnecting(to: deviceB))
        XCTAssertFalse(processor.isConnecting(to: deviceA))

        processor.dispatch(.didConnect(peripheralId: deviceB))
        guard case .success = connect.outcome() else { return XCTFail("the connect did not complete") }
        XCTAssertEqual(processor.connectedPeripheralId, deviceB)
        XCTAssertFalse(processor.isConnecting(to: deviceB))

        processor.cancelConnect()
        XCTAssertEqual(processor.connectedPeripheralId, deviceB, "a late cancel ended a completed connect")

        processor.dispatch(.didDisconnect(peripheralId: deviceB, error: nil))
        XCTAssertNil(processor.connectedPeripheralId)
    }

    /// A disconnect wait for the connected peripheral resumes on its
    /// didDisconnect, after the disconnect callbacks ran. For a peripheral
    /// that is not connected it resumes at once, and the caller is told not
    /// to cancel a connection.
    func testDisconnectWaitsForTheConnectedPeripheralOnly() {
        let processor = connected(to: deviceB)
        let calledBack = DispatchSemaphore(value: 0)
        processor.onDisconnect { _ in calledBack.signal() }

        nonisolated(unsafe) var mustCancel = true
        let other = Wait<Void> { mustCancel = processor.beginDisconnect(from: self.deviceA, $0) }
        XCTAssertFalse(mustCancel)
        guard case .success = other.outcome() else { return XCTFail("the wait for an unconnected peripheral did not resume") }

        let disconnect = Wait<Void> { mustCancel = processor.beginDisconnect(from: self.deviceB, $0) }
        XCTAssertTrue(mustCancel)
        XCTAssertNil(disconnect.outcome(timeout: 0.1), "the disconnect wait resumed before the disconnect")
        processor.dispatch(.didDisconnect(peripheralId: deviceB, error: nil))
        guard case .success = disconnect.outcome() else { return XCTFail("the disconnect wait did not resume") }
        XCTAssertEqual(calledBack.wait(timeout: .now()), .success, "the callbacks had not run when the wait resumed")
    }

    /// Starting a connect while another connection is served ends that one,
    /// so none of its waits or streams is left pending.
    func testBeginConnectEndsTheServedConnection() {
        let processor = connected(to: deviceA)
        let read = Wait<Data> { processor.setReadContinuation(forChar: "2A19", $0) }
        let finished = DispatchSemaphore(value: 0)
        let stream = registerStream(processor, finished: finished)

        let connect = Wait<Void> { processor.beginConnect(to: self.deviceB, $0) }
        guard case .failure(BLEError.connectionFailed) = read.outcome() else {
            return XCTFail("the replaced connection's read was left pending")
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(processor.connectedPeripheralId)
        XCTAssertTrue(processor.isConnecting(to: deviceB))

        processor.cancelConnect()
        _ = connect.outcome()
        withExtendedLifetime(stream) {}
    }

    /// A disconnect of another peripheral leaves the connection's pending
    /// operations, streams and state alone; the connected one's disconnect
    /// ends them.
    func testDisconnectOfAnotherPeripheralLeavesTheConnectionAlone() {
        let processor = connected(to: deviceB)
        let read = Wait<Data> { processor.setReadContinuation(forChar: "2A19", $0) }
        let finished = DispatchSemaphore(value: 0)
        let stream = registerStream(processor, finished: finished)
        let disconnected = DispatchSemaphore(value: 0)
        processor.onDisconnect { id in
            XCTAssertEqual(id, self.deviceB)
            disconnected.signal()
        }

        XCTAssertTrue(ignores(processor, .didDisconnect(peripheralId: deviceA, error: nil)))
        XCTAssertNil(read.outcome(timeout: 0.1), "another peripheral's disconnect failed the read")
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut, "another peripheral's disconnect ended the stream")

        processor.dispatch(.didDisconnect(peripheralId: deviceB, error: nil))
        guard case .failure(BLEError.connectionFailed) = read.outcome() else {
            return XCTFail("the connected peripheral's disconnect did not fail the read")
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(disconnected.wait(timeout: .now() + 1), .success)
        withExtendedLifetime(stream) {}
    }

    /// GATT results of another peripheral do not complete the connection's
    /// operations.
    func testGATTEventsOfAnotherPeripheralAreIgnored() {
        let processor = connected(to: deviceB)
        let read = Wait<Data> { processor.setReadContinuation(forChar: "2A19", $0) }

        XCTAssertTrue(ignores(processor, .didUpdateValue(peripheralId: deviceA, characteristicUUID: "2A19",
                                                         value: Data([0x01]), error: nil)))
        XCTAssertNil(read.outcome(timeout: 0.1), "another peripheral's value completed the read")

        processor.dispatch(.didUpdateValue(peripheralId: deviceB, characteristicUUID: "2A19",
                                           value: Data([0x64]), error: nil))
        guard case .success(let value) = read.outcome() else {
            return XCTFail("the connected peripheral's value did not complete the read")
        }
        XCTAssertEqual(value, Data([0x64]))
    }

    /// A scan stream registered the way BLECentral.scan does. `finished` is
    /// signalled once the stream has ended.
    private func registerScan(_ processor: BLEEventProcessor, finished: DispatchSemaphore) -> AsyncStream<DiscoveredDevice> {
        AsyncStream<DiscoveredDevice> { continuation in
            processor.setScanContinuation(continuation)
            continuation.onTermination = { _ in
                processor.setScanContinuation(nil)
                finished.signal()
            }
        }
    }

    /// Bluetooth leaving poweredOn (powered off, access revoked, the stack
    /// resetting, no radio) ends everything that waits on the radio: the
    /// connection's one-shot waits fail with bluetoothUnavailable, its
    /// notification streams and the scan finish, and blew is no longer
    /// connected.
    func testBluetoothBecomingUnavailableEndsTheConnectionAndTheScan() {
        for state in [CBManagerState.poweredOff, .unauthorized, .resetting, .unsupported] {
            let processor = connected(to: deviceB)
            let read = Wait<Data> { processor.setReadContinuation(forChar: "2A19", $0) }
            let write = Wait<Void> { processor.setWriteContinuation(forChar: "FFF1", $0) }
            let streamFinished = DispatchSemaphore(value: 0)
            let stream = registerStream(processor, finished: streamFinished)
            let scanFinished = DispatchSemaphore(value: 0)
            let scan = registerScan(processor, finished: scanFinished)
            let disconnected = DispatchSemaphore(value: 0)
            processor.onDisconnect { _ in disconnected.signal() }

            processor.dispatch(.centralStateChanged(state))

            guard case .failure(BLEError.bluetoothUnavailable) = read.outcome() else {
                return XCTFail("\(state.rawValue): the read did not fail with bluetoothUnavailable")
            }
            guard case .failure(BLEError.bluetoothUnavailable) = write.outcome() else {
                return XCTFail("\(state.rawValue): the write did not fail with bluetoothUnavailable")
            }
            XCTAssertEqual(streamFinished.wait(timeout: .now() + 1), .success, "\(state.rawValue): the notification stream did not end")
            guard case .failure(BLEError.bluetoothUnavailable) = streamEnd(stream) else {
                return XCTFail("\(state.rawValue): the notification stream did not end with bluetoothUnavailable")
            }
            XCTAssertEqual(scanFinished.wait(timeout: .now() + 1), .success, "\(state.rawValue): the scan did not end")
            XCTAssertEqual(disconnected.wait(timeout: .now() + 1), .success, "\(state.rawValue): the disconnect callbacks did not run")
            XCTAssertNil(processor.connectedPeripheralId, "\(state.rawValue): still connected")
            withExtendedLifetime((stream, scan)) {}
        }
    }

    /// How a stream that has already ended ends for its reader: success when
    /// it finished, the error it threw otherwise.
    private func streamEnd(_ stream: AsyncThrowingStream<Data, Error>) -> Result<Void, Error> {
        let end = Wait<Void> { cont in
            Task {
                do {
                    for try await _ in stream {}
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return end.outcome() ?? .failure(BLEError.timeout)
    }

    /// The connected peripheral's disconnect ends its notification streams
    /// with the reason, so `sub` reports it instead of exiting 0.
    func testDisconnectEndsTheNotificationStreamWithAnError() {
        let processor = connected(to: deviceB)
        let finished = DispatchSemaphore(value: 0)
        let stream = registerStream(processor, finished: finished)
        processor.dispatch(.didDisconnect(peripheralId: deviceB, error: "link lost"))
        guard case .failure(BLEError.connectionFailed) = streamEnd(stream) else {
            return XCTFail("the stream did not end with connectionFailed")
        }
    }

    /// A connection whose setup failed (service discovery threw or was
    /// cancelled) is ended at once, as a disconnect would end it: blew is not
    /// connected, its waits fail, the disconnect callbacks run, and the late
    /// didDisconnect of the cancelled connection is dropped.
    func testEndConnectionEndsTheConnectionItNames() {
        let processor = connected(to: deviceB)
        let discover = Wait<[String]> { processor.setDiscoverServicesContinuation($0) }
        let disconnected = DispatchSemaphore(value: 0)
        processor.onDisconnect { _ in disconnected.signal() }

        processor.endConnection(to: deviceA, .connectionFailed("setup failed"))
        XCTAssertEqual(processor.connectedPeripheralId, deviceB, "ending another peripheral's connection ended this one")
        XCTAssertNil(discover.outcome(timeout: 0.1))

        processor.endConnection(to: deviceB, .connectionFailed("setup failed"))
        XCTAssertNil(processor.connectedPeripheralId)
        guard case .failure(BLEError.connectionFailed) = discover.outcome() else {
            return XCTFail("the pending discovery was not failed")
        }
        XCTAssertEqual(disconnected.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(ignores(processor, .didDisconnect(peripheralId: deviceB, error: nil)),
                      "the ended connection's late didDisconnect was served")
    }

    /// A connect still waiting for its device fails when Bluetooth goes away.
    func testBluetoothPowerOffFailsAWaitingConnect() {
        let processor = BLEEventProcessor(eventQueue: BLEEventQueue())
        let connect = Wait<Void> { processor.beginConnect(to: self.deviceB, $0) }
        processor.dispatch(.centralStateChanged(.poweredOff))
        guard case .failure(BLEError.bluetoothUnavailable) = connect.outcome() else {
            return XCTFail("the waiting connect did not fail with bluetoothUnavailable")
        }
        XCTAssertFalse(processor.isConnecting(to: deviceB))
    }

    /// Bluetooth reporting poweredOn ends nothing, and the state callbacks
    /// see every state.
    func testPoweredOnLeavesTheConnectionAlone() {
        let processor = connected(to: deviceB)
        let read = Wait<Data> { processor.setReadContinuation(forChar: "2A19", $0) }
        let seen = DispatchSemaphore(value: 0)
        processor.onStateChange { state in if state == .poweredOn { seen.signal() } }

        processor.dispatch(.centralStateChanged(.poweredOn))
        XCTAssertEqual(seen.wait(timeout: .now() + 1), .success)
        XCTAssertNil(read.outcome(timeout: 0.1), "poweredOn failed the read")
        XCTAssertEqual(processor.connectedPeripheralId, deviceB)
    }
}
