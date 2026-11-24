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

    /// Turning notifications off is acknowledged with isNotifying false.
    /// That acknowledgement, of a subscribe that was given up, settles no
    /// subscribe: one waiting for its own confirmation keeps waiting.
    func testNotificationsOffAcknowledgementDoesNotSettleASubscribe() {
        let processor = connected(to: deviceB)
        let subscribe = start(processor) { .subscribe(characteristic: "TX", $0) }
        let off = BLEEvent.didUpdateNotificationState(peripheralId: deviceB, characteristicUUID: "TX",
                                                      isNotifying: false, error: nil)
        XCTAssertTrue(ignores(processor, off), "notifications turning off settled a subscribe")
        let on = BLEEvent.didUpdateNotificationState(peripheralId: deviceB, characteristicUUID: "TX",
                                                     isNotifying: true, error: nil)
        XCTAssertFalse(ignores(processor, on), "the confirmation did not settle the subscribe")
        XCTAssertNotNil(subscribe.wait.outcome())
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
            _ = processor.makeTicket()
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
        let read = startRead(processor, "2A19").wait
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
        let read = startRead(processor, "2A19").wait
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
        let read = startRead(processor, "2A19").wait

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
            let read = startRead(processor, "2A19").wait
            let write = startWrite(processor, "FFF1").wait
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
        let discover = start(processor) { .discoverServices($0) }.wait
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
        let read = startRead(processor, "2A19").wait
        let seen = DispatchSemaphore(value: 0)
        processor.onStateChange { state in if state == .poweredOn { seen.signal() } }

        processor.dispatch(.centralStateChanged(.poweredOn))
        XCTAssertEqual(seen.wait(timeout: .now() + 1), .success)
        XCTAssertNil(read.outcome(timeout: 0.1), "poweredOn failed the read")
        XCTAssertEqual(processor.connectedPeripheralId, deviceB)
    }

    // MARK: - Requests answered in issue order

    /// A request registered and issued the way BLECentral issues one, with
    /// the handle that cancels it.
    private struct Started<T: Sendable> {
        let wait: Wait<T>
        let cancel: () -> Void
    }

    /// Stands in for blew.cb, where a request is issued.
    private let gattQueue = DispatchQueue(label: "blew.test.cb")

    /// Submit a request to the connected peripheral (or `peripheral`), let it
    /// be issued, and return its wait. `call` stands in for the CoreBluetooth
    /// call; `cancelledFirst` cancels the ticket before the wait registers.
    private func start<T: Sendable>(
        _ p: BLEEventProcessor, to peripheral: UUID? = nil, cancelledFirst: Bool = false,
        undo: (@Sendable () -> Void)? = nil, call: @escaping @Sendable () -> Void = {},
        _ makeRequest: @escaping @Sendable (CheckedContinuation<T, Error>) -> CentralRequest
    ) -> Started<T> {
        let ticket = p.makeTicket()
        if cancelledFirst { p.cancel(ticket, undo: undo) }
        let target = peripheral ?? p.connectedPeripheralId ?? UUID()
        let wait = Wait<T> { p.submit(ticket, makeRequest($0), to: target, on: self.gattQueue, call: call) }
        gattQueue.sync {}
        return Started(wait: wait, cancel: { p.cancel(ticket, undo: undo) })
    }

    private func startRead(_ p: BLEEventProcessor, _ char: String, cancelledFirst: Bool = false) -> Started<Data> {
        start(p, cancelledFirst: cancelledFirst) { .read(characteristic: char, $0) }
    }

    private func startWrite(_ p: BLEEventProcessor, _ char: String) -> Started<Void> {
        start(p) { .write(characteristic: char, $0) }
    }

    /// A write without response whose poll finds the peripheral ready when
    /// `ready` says so, and then sends it with `sent`.
    private func startWriteWithoutResponse(_ p: BLEEventProcessor, ready: @escaping @Sendable () -> Bool,
                                           sent: @escaping @Sendable () -> Void) -> Started<Void> {
        let ticket = p.makeTicket()
        let peripheral = p.connectedPeripheralId ?? UUID()
        let wait = Wait<Void> { cont in
            p.waitToWrite(ticket, cont, to: peripheral) {
                if ready() { p.sendIfWaiting(ticket, send: sent) }
            }
        }
        return Started(wait: wait, cancel: { p.cancel(ticket) })
    }

    private func value(_ char: String, _ bytes: [UInt8], error: String? = nil) -> BLEEvent {
        .didUpdateValue(peripheralId: deviceB, characteristicUUID: char, value: Data(bytes), error: error)
    }

    private func written(_ char: String, error: String? = nil) -> BLEEvent {
        .didWriteValue(peripheralId: deviceB, characteristicUUID: char, error: error)
    }

    private func isCancellation<T>(_ outcome: Result<T, Error>?) -> Bool {
        if case .failure(let error) = outcome { return error is CancellationError }
        return false
    }

    /// Two reads of one characteristic in flight: CoreBluetooth answers them
    /// in the order they were issued, and each gets its own answer.
    func testConcurrentReadsOfOneCharacteristicEachGetTheirOwnValue() {
        let processor = connected(to: deviceB)
        let first = startRead(processor, "2A19")
        let second = startRead(processor, "2A19")
        processor.dispatch(value("2A19", [1]))
        processor.dispatch(value("2A19", [2]))
        XCTAssertEqual(try first.wait.outcome()?.get(), Data([1]), "the first read lost its answer")
        XCTAssertEqual(try second.wait.outcome()?.get(), Data([2]))
    }

    /// A read cancelled after it was issued still gets its answer from the
    /// device. That late answer is the cancelled read's, not the answer to a
    /// read issued after it.
    func testCancelledReadsLateValueDoesNotCompleteTheNextRead() {
        let processor = connected(to: deviceB)
        let abandoned = startRead(processor, "2A19")
        abandoned.cancel()
        XCTAssertTrue(isCancellation(abandoned.wait.outcome()))
        let next = startRead(processor, "2A19")
        processor.dispatch(value("2A19", [0xAA]))
        XCTAssertNil(next.wait.outcome(timeout: 0.2), "the cancelled read's late value completed the next read")
        processor.dispatch(value("2A19", [0xBB]))
        XCTAssertEqual(try next.wait.outcome()?.get(), Data([0xBB]))
    }

    /// A cancellation that runs before the request is registered ends it at
    /// once: the wait does not outlive the cancellation.
    func testRequestCancelledBeforeItIsRegisteredEndsAtOnce() {
        let processor = connected(to: deviceB)
        let read = startRead(processor, "2A19", cancelledFirst: true)
        XCTAssertTrue(isCancellation(read.wait.outcome(timeout: 0.5)), "a cancelled read still waits")
    }

    /// A notification that arrives while a read is in flight is not taken
    /// from the stream: CoreBluetooth reports both through one callback, so
    /// the stream gets every value of the characteristic.
    func testNotificationWhileAReadIsOutstandingReachesTheStream() {
        let processor = connected(to: deviceB)
        let finished = DispatchSemaphore(value: 0)
        let stream = registerStream(processor, finished: finished)
        let read = startRead(processor, "TX")
        processor.dispatch(value("TX", [7]))
        let received = DispatchSemaphore(value: 0)
        let first = SharedBox<Data?>(nil)
        let reader = Task {
            for try await value in stream {
                first.set(value)
                received.signal()
                break
            }
        }
        XCTAssertEqual(received.wait(timeout: .now() + 1), .success, "the read took the notification from the stream")
        XCTAssertEqual(first.get(), Data([7]))
        XCTAssertNotNil(read.wait.outcome(), "the read did not complete")
        reader.cancel()
    }

    /// A write with response cancelled after it was issued keeps its place:
    /// its late acknowledgement does not complete the next write, and an
    /// error in that acknowledgement does not fail it.
    func testCancelledWritesLateAcknowledgementDoesNotCompleteTheNextWrite() {
        let processor = connected(to: deviceB)
        let abandoned = startWrite(processor, "FFF1")
        abandoned.cancel()
        XCTAssertTrue(isCancellation(abandoned.wait.outcome()))
        let next = startWrite(processor, "FFF1")
        processor.dispatch(written("FFF1", error: "Write not permitted"))
        XCTAssertNil(next.wait.outcome(timeout: 0.2), "the cancelled write's late acknowledgement settled the next write")
        processor.dispatch(written("FFF1"))
        if case .failure(let error) = next.wait.outcome() { XCTFail("the next write failed: \(error)") }
        XCTAssertNotNil(next.wait.outcome())
    }

    /// Two writes without response wait for the peripheral to be ready; one
    /// ready event wakes both, and each is sent once.
    func testEveryWriteWithoutResponseWaitingIsWokenWhenReady() {
        let processor = connected(to: deviceB)
        let ready = SharedBox(false)
        let sent = SharedBox(0)
        let first = startWriteWithoutResponse(processor, ready: { ready.get() }, sent: { sent.update { $0 += 1 } })
        let second = startWriteWithoutResponse(processor, ready: { ready.get() }, sent: { sent.update { $0 += 1 } })
        ready.set(true)
        processor.dispatch(.isReadyToSendWriteWithoutResponse(peripheralId: deviceB))
        XCTAssertNotNil(first.wait.outcome(), "the first write without response was never woken")
        XCTAssertNotNil(second.wait.outcome())
        XCTAssertEqual(sent.get(), 2)
    }

    /// A write without response cancelled while it waits is never sent.
    func testCancelledWriteWithoutResponseIsNotSent() {
        let processor = connected(to: deviceB)
        let ready = SharedBox(false)
        let sent = SharedBox(0)
        let write = startWriteWithoutResponse(processor, ready: { ready.get() }, sent: { sent.update { $0 += 1 } })
        write.cancel()
        XCTAssertTrue(isCancellation(write.wait.outcome()))
        ready.set(true)
        processor.dispatch(.isReadyToSendWriteWithoutResponse(peripheralId: deviceB))
        XCTAssertEqual(sent.get(), 0, "a cancelled write without response was sent")
    }

    /// A request whose peripheral disconnected before it went out fails, and
    /// its CoreBluetooth call is not made.
    func testRequestToAPeripheralNoLongerConnectedIsNotIssued() {
        let processor = connected(to: deviceB)
        let issued = SharedBox(false)
        let read = start(processor, to: deviceA, call: { issued.set(true) }) { .read(characteristic: "2A19", $0) }
        if case .failure(BLEError.notConnected)? = read.wait.outcome() {} else {
            XCTFail("a request to a peripheral that is not connected did not fail with notConnected")
        }
        XCTAssertFalse(issued.get())
    }

    /// A subscribe given up after its request went out queues the undo
    /// (turning notifications off); one given up before it went out is
    /// never issued, so there is nothing to undo.
    func testCancelledSubscribeUndoesOnlyAnIssuedRequest() {
        let processor = connected(to: deviceB)
        let undone = SharedBox(0)
        let issued = SharedBox(0)
        let early = start(processor, cancelledFirst: true, undo: { undone.update { $0 += 1 } },
                          call: { issued.update { $0 += 1 } }) { .subscribe(characteristic: "TX", $0) }
        XCTAssertTrue(isCancellation(early.wait.outcome()))
        XCTAssertEqual(issued.get(), 0, "a subscribe cancelled first was issued")
        XCTAssertEqual(undone.get(), 0)

        let late = start(processor, undo: { undone.update { $0 += 1 } },
                         call: { issued.update { $0 += 1 } }) { .subscribe(characteristic: "TX", $0) }
        late.cancel()
        XCTAssertTrue(isCancellation(late.wait.outcome()))
        XCTAssertEqual(issued.get(), 1)
        XCTAssertEqual(undone.get(), 1, "an issued subscribe that was given up was not undone")
    }

    /// A cancellation that lands after the wait registered but before the
    /// request went out on blew.cb ends the wait, and the request is never
    /// made, so there is nothing to undo.
    func testRequestCancelledBeforeItGoesOutIsNotIssued() {
        let processor = connected(to: deviceB)
        let issued = SharedBox(false)
        let undone = SharedBox(false)
        let ticket = processor.makeTicket()
        gattQueue.suspend()
        let wait = Wait<Void> {
            processor.submit(ticket, .subscribe(characteristic: "TX", $0), to: self.deviceB,
                             on: self.gattQueue) { issued.set(true) }
        }
        processor.cancel(ticket) { undone.set(true) }
        gattQueue.resume()
        gattQueue.sync {}
        XCTAssertTrue(isCancellation(wait.outcome()))
        XCTAssertFalse(issued.get(), "a request cancelled before it went out was issued")
        XCTAssertFalse(undone.get())
    }

    /// A subscribe given up after its request went out keeps its place: the
    /// device's late confirmation is its own, not the next subscribe's.
    func testAbandonedSubscribesLateConfirmationDoesNotSettleTheNextSubscribe() {
        let processor = connected(to: deviceB)
        let abandoned = start(processor) { .subscribe(characteristic: "TX", $0) }
        abandoned.cancel()
        XCTAssertTrue(isCancellation(abandoned.wait.outcome()))
        let next = start(processor) { .subscribe(characteristic: "TX", $0) }
        let on = BLEEvent.didUpdateNotificationState(peripheralId: deviceB, characteristicUUID: "TX",
                                                     isNotifying: true, error: nil)
        processor.dispatch(on)
        XCTAssertNil(next.wait.outcome(timeout: 0.2), "the abandoned subscribe's confirmation settled the next one")
        processor.dispatch(on)
        XCTAssertNotNil(next.wait.outcome())
    }

    /// A write without response waiting for room fails when the connection
    /// ends, and one for a peripheral that is not connected fails at once.
    func testWriteWithoutResponseFailsWhenNotConnected() {
        let processor = connected(to: deviceB)
        let waiting = startWriteWithoutResponse(processor, ready: { false }, sent: {})
        processor.dispatch(.didDisconnect(peripheralId: deviceB, error: nil))
        if case .failure(BLEError.connectionFailed)? = waiting.wait.outcome() {} else {
            XCTFail("a waiting write without response outlived the connection")
        }
        let late = startWriteWithoutResponse(processor, ready: { true }, sent: {})
        if case .failure(BLEError.notConnected)? = late.wait.outcome() {} else {
            XCTFail("a write without response with no connection did not fail with notConnected")
        }
    }

    /// An error in a value callback answers the read in flight; it is not a
    /// notification, and the stream does not see it.
    func testReadErrorGoesToTheReadNotTheStream() {
        let processor = connected(to: deviceB)
        let finished = DispatchSemaphore(value: 0)
        let stream = registerStream(processor, finished: finished)
        let read = startRead(processor, "TX")
        processor.dispatch(.didUpdateValue(peripheralId: deviceB, characteristicUUID: "TX", value: nil,
                                           error: "Read not permitted"))
        if case .failure(BLEError.readFailed)? = read.wait.outcome() {} else { XCTFail("the read did not fail") }
        processor.dispatch(value("TX", [9]))
        let first = SharedBox<Data?>(nil)
        let received = DispatchSemaphore(value: 0)
        let reader = Task {
            for try await value in stream {
                first.set(value)
                received.signal()
                break
            }
        }
        XCTAssertEqual(received.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(first.get(), Data([9]), "the stream saw the read's error answer")
        reader.cancel()
    }
}

/// A value shared between a test and its tasks.
private final class SharedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
    func update(_ body: (inout T) -> Void) { lock.withLock { body(&value) } }
}
