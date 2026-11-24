import XCTest
import CoreBluetooth
@testable import BLEManager

/// Read and write requests from a remote central, answered by `GATTStore`
/// with ATT semantics (Core spec Vol 3 Part F 3.4.4.5, 3.4.6).
final class GATTStoreOffsetTests: XCTestCase {
    private let battery = BLEUUID(CBUUID(string: "2A19"))
    private let heartRate = BLEUUID(CBUUID(string: "2A37"))

    func testReadReturnsTheValueFromTheOffset() {
        XCTAssertEqual(GATTStore.read(Data([1, 2, 3]), at: 0), .success(Data([1, 2, 3])))
        XCTAssertEqual(GATTStore.read(Data([1, 2, 3]), at: 1), .success(Data([2, 3])))
    }

    func testReadAtTheEndIsEmpty() {
        XCTAssertEqual(GATTStore.read(Data([1, 2, 3]), at: 3), .success(Data()))
    }

    func testReadPastTheEndIsInvalidOffset() {
        XCTAssertEqual(GATTStore.read(Data([1, 2, 3]), at: 4), .failure(.invalidOffset))
        XCTAssertEqual(GATTStore.read(Data([1, 2, 3]), at: -1), .failure(.invalidOffset))
    }

    func testReadOfAnUnsetValue() {
        let store = GATTStore()
        XCTAssertEqual(store.read(battery, at: 0), .success(Data()))
        XCTAssertEqual(store.read(battery, at: 1), .failure(.invalidOffset))
    }

    func testReadOfASlicedValueStartsAtTheOffset() {
        let sliced = Data([9, 9, 1, 2, 3]).dropFirst(2)
        XCTAssertEqual(GATTStore.read(sliced, at: 1), .success(Data([2, 3])))
    }

    func testWriteAtOffsetZeroReplacesTheValue() {
        let store = GATTStore()
        store.setValue(Data([1, 2, 3, 4]), for: battery)
        XCTAssertEqual(store.write([ATTWrite(characteristic: battery, offset: 0, value: Data([7]))]),
                       .success([battery: Data([7])]))
        XCTAssertEqual(store.getValue(for: battery), Data([7]))
    }

    func testPreparedWriteAssemblesTheFragmentsInOrder() {
        let store = GATTStore()
        let fragments = [
            ATTWrite(characteristic: battery, offset: 0, value: Data([1, 2])),
            ATTWrite(characteristic: battery, offset: 2, value: Data([3, 4])),
            ATTWrite(characteristic: battery, offset: 4, value: Data([5])),
        ]
        XCTAssertEqual(store.write(fragments), .success([battery: Data([1, 2, 3, 4, 5])]))
        XCTAssertEqual(store.getValue(for: battery), Data([1, 2, 3, 4, 5]))
    }

    func testPreparedWriteOverALongerValueDropsTheOldTail() {
        let values = [battery: Data(repeating: 0xEE, count: 10)]
        let fragments = [
            ATTWrite(characteristic: battery, offset: 0, value: Data([1, 2])),
            ATTWrite(characteristic: battery, offset: 2, value: Data([3])),
        ]
        XCTAssertEqual(GATTStore.apply(fragments, to: values), .success([battery: Data([1, 2, 3])]))
    }

    func testWritePastTheEndIsInvalidOffsetAndChangesNothing() {
        let store = GATTStore()
        store.setValue(Data([1, 2]), for: battery)
        let writes = [
            ATTWrite(characteristic: battery, offset: 0, value: Data([9])),
            ATTWrite(characteristic: battery, offset: 5, value: Data([1])),
        ]
        XCTAssertEqual(store.write(writes), .failure(.invalidOffset))
        XCTAssertEqual(store.getValue(for: battery), Data([1, 2]))
        XCTAssertEqual(store.write([ATTWrite(characteristic: battery, offset: -1, value: Data())]),
                       .failure(.invalidOffset))
    }

    func testWriteBeyondTheATTMaximumIsInvalidLengthAndChangesNothing() {
        let store = GATTStore()
        let fragments = [
            ATTWrite(characteristic: battery, offset: 0, value: Data(repeating: 1, count: 500)),
            ATTWrite(characteristic: battery, offset: 500, value: Data(repeating: 2, count: 13)),
        ]
        XCTAssertEqual(store.write(fragments), .failure(.invalidAttributeValueLength))
        XCTAssertNil(store.getValue(for: battery))
        XCTAssertEqual(store.write([ATTWrite(characteristic: battery, offset: 0,
                                             value: Data(repeating: 3, count: 513))]),
                       .failure(.invalidAttributeValueLength))
    }

    func testWriteOfTheATTMaximumIsAccepted() {
        let fragments = [
            ATTWrite(characteristic: battery, offset: 0, value: Data(repeating: 1, count: 500)),
            ATTWrite(characteristic: battery, offset: 500, value: Data(repeating: 2, count: 12)),
        ]
        guard case .success(let values) = GATTStore.apply(fragments, to: [:]) else {
            return XCTFail("a 512-byte value is valid")
        }
        XCTAssertEqual(values[battery]?.count, GATTStore.maxValueLength)
    }

    func testOneRequestBatchWritesSeveralCharacteristics() {
        let writes = [
            ATTWrite(characteristic: battery, offset: 0, value: Data([1])),
            ATTWrite(characteristic: heartRate, offset: 0, value: Data([2, 3])),
            ATTWrite(characteristic: heartRate, offset: 2, value: Data([4])),
        ]
        XCTAssertEqual(GATTStore.apply(writes, to: [heartRate: Data([0xFF])]),
                       .success([battery: Data([1]), heartRate: Data([2, 3, 4])]))
    }
}

/// Notifications CoreBluetooth's transmit queue has no room for.
final class NotificationQueueTests: XCTestCase {
    func testSentAtOnceWhenTheTransmitQueueHasRoom() {
        var queue = NotificationQueue<Int>(capacity: 2)
        var sent: [Int] = []
        XCTAssertEqual(queue.submit(1) { sent.append($0); return true }, .sent)
        XCTAssertEqual(sent, [1])
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testQueuedWhenTheTransmitQueueIsFullAndSentInOrderWhenReady() {
        var queue = NotificationQueue<Int>(capacity: 4)
        XCTAssertEqual(queue.submit(1) { _ in false }, .queued(pending: 1))
        // A later value waits behind the queued one even when there is room.
        var sent: [Int] = []
        XCTAssertEqual(queue.submit(2) { sent.append($0); return true }, .queued(pending: 2))
        XCTAssertEqual(sent, [])
        XCTAssertEqual(queue.drain { sent.append($0); return true }, 2)
        XCTAssertEqual(sent, [1, 2])
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testDrainStopsWhenTheTransmitQueueFillsAgain() {
        var queue = NotificationQueue<Int>(capacity: 4)
        for n in 1...3 { _ = queue.submit(n) { _ in false } }
        var sent: [Int] = []
        XCTAssertEqual(queue.drain { n in
            guard n < 3 else { return false }
            sent.append(n)
            return true
        }, 2)
        XCTAssertEqual(sent, [1, 2])
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertEqual(queue.drain { sent.append($0); return true }, 1)
        XCTAssertEqual(sent, [1, 2, 3])
    }

    func testAFullQueueRejectsTheNotification() {
        var queue = NotificationQueue<Int>(capacity: 2)
        XCTAssertEqual(queue.submit(1) { _ in false }, .queued(pending: 1))
        XCTAssertEqual(queue.submit(2) { _ in false }, .queued(pending: 2))
        XCTAssertEqual(queue.submit(3) { _ in true }, .full)
        var sent: [Int] = []
        _ = queue.drain { sent.append($0); return true }
        XCTAssertEqual(sent, [1, 2])
    }

    func testRemoveAllDropsWhatIsPending() {
        var queue = NotificationQueue<Int>(capacity: 2)
        _ = queue.submit(1) { _ in false }
        queue.removeAll()
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(queue.drain { _ in XCTFail("nothing to send"); return true }, 0)
    }
}

/// Waiters for CoreBluetooth callbacks that answer one request each.
final class PendingCallbacksTests: XCTestCase {
    private typealias Callbacks = PendingCallbacks<String, String>

    private func issued(_ callbacks: inout Callbacks, _ key: String, _ waiter: String) -> Callbacks.Ticket {
        let ticket = callbacks.makeTicket()
        XCTAssertTrue(callbacks.add(ticket, waiter))
        XCTAssertTrue(callbacks.issue(ticket, as: key))
        return ticket
    }

    func testTheCallbackFindsItsWaiter() {
        var callbacks = Callbacks()
        _ = issued(&callbacks, "adv", "A")
        _ = issued(&callbacks, "svc", "S")
        XCTAssertEqual(callbacks.complete("svc"), .waiter("S"))
        XCTAssertEqual(callbacks.complete("adv"), .waiter("A"))
        XCTAssertEqual(callbacks.complete("adv"), .unexpected)
    }

    func testACancelledRequestKeepsItsPlaceForTheCallbackItWillGet() {
        var callbacks = Callbacks()
        let first = issued(&callbacks, "adv", "A")
        XCTAssertEqual(callbacks.cancel(first), "A")
        _ = issued(&callbacks, "adv", "B")
        XCTAssertEqual(callbacks.complete("adv"), .abandoned(laterRequests: 1))
        XCTAssertEqual(callbacks.complete("adv"), .waiter("B"))
    }

    func testTheLastAbandonedCallbackReportsNoLaterRequest() {
        var callbacks = Callbacks()
        let ticket = issued(&callbacks, "adv", "A")
        XCTAssertEqual(callbacks.cancel(ticket), "A")
        XCTAssertEqual(callbacks.complete("adv"), .abandoned(laterRequests: 0))
    }

    func testCancelBeforeTheWaiterIsAddedPreventsTheRequest() {
        var callbacks = Callbacks()
        let ticket = callbacks.makeTicket()
        XCTAssertNil(callbacks.cancel(ticket))
        XCTAssertFalse(callbacks.add(ticket, "A"))
        XCTAssertFalse(callbacks.issue(ticket, as: "adv"))
        XCTAssertEqual(callbacks.complete("adv"), .unexpected)
    }

    func testCancelBeforeTheRequestIsIssuedRemovesIt() {
        var callbacks = Callbacks()
        let ticket = callbacks.makeTicket()
        XCTAssertTrue(callbacks.add(ticket, "A"))
        XCTAssertEqual(callbacks.cancel(ticket), "A")
        XCTAssertFalse(callbacks.issue(ticket, as: "adv"))
        XCTAssertEqual(callbacks.complete("adv"), .unexpected)
    }

    func testCancelAfterTheCallbackDoesNothing() {
        var callbacks = Callbacks()
        let ticket = issued(&callbacks, "adv", "A")
        XCTAssertEqual(callbacks.complete("adv"), .waiter("A"))
        XCTAssertNil(callbacks.cancel(ticket))
        XCTAssertNil(callbacks.cancel(ticket))
    }

    func testRemoveAllReturnsEveryWaiterStillWaiting() {
        var callbacks = Callbacks()
        _ = issued(&callbacks, "svc", "S")
        let abandoned = issued(&callbacks, "adv", "A")
        _ = callbacks.cancel(abandoned)
        let unissued = callbacks.makeTicket()
        XCTAssertTrue(callbacks.add(unissued, "U"))
        XCTAssertEqual(Set(callbacks.removeAll()), ["S", "U"])
        XCTAssertFalse(callbacks.issue(unissued, as: "adv"))
        XCTAssertEqual(callbacks.complete("svc"), .unexpected)
        XCTAssertEqual(callbacks.complete("adv"), .unexpected)
    }

    func testATicketReservedBeforeRemoveAllCanStillBeUsed() {
        var callbacks = Callbacks()
        let ticket = callbacks.makeTicket()
        XCTAssertEqual(callbacks.removeAll(), [])
        XCTAssertTrue(callbacks.add(ticket, "A"))
        XCTAssertTrue(callbacks.issue(ticket, as: "adv"))
        XCTAssertEqual(callbacks.complete("adv"), .waiter("A"))
    }
}

/// What the peripheral delegate does when Bluetooth leaves poweredOn.
final class PeripheralPowerStateTests: XCTestCase {
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Result<Void, Error>] = []
        func append(_ r: Result<Void, Error>) { lock.withLock { values.append(r) } }
        var all: [Result<Void, Error>] { lock.withLock { values } }
    }

    private func pendingRequest(_ delegate: BLEPeripheralDelegate, _ key: PeripheralRequest,
                                into results: Results) {
        let ticket = delegate.withCallbacks { $0.makeTicket() }
        XCTAssertTrue(delegate.withCallbacks { $0.add(ticket, { results.append($0) }) })
        XCTAssertTrue(delegate.withCallbacks { $0.issue(ticket, as: key) })
    }

    private func notification() -> PendingNotification {
        PendingNotification(
            value: Data([1]),
            characteristic: CBMutableCharacteristic(
                type: CBUUID(string: "2A19"), properties: [.notify], value: nil, permissions: []))
    }

    func testLeavingPoweredOnFailsEveryPendingWaitAndClearsTheQueue() {
        let delegate = BLEPeripheralDelegate(store: GATTStore())
        var lostState: CBManagerState?
        delegate.onLeftPoweredOn = { lostState = $0 }
        let results = Results()
        pendingRequest(delegate, .advertising, into: results)
        pendingRequest(delegate, .addService(BLEUUID(CBUUID(string: "180D"))), into: results)
        XCTAssertEqual(delegate.submitNotification(notification()) { _ in false }, .queued(pending: 1))

        delegate.bluetoothStateChanged(.poweredOff)

        XCTAssertEqual(lostState, .poweredOff)
        XCTAssertEqual(results.all.count, 2)
        for result in results.all {
            guard case .failure(BLEError.bluetoothUnavailable(let message)) = result else {
                return XCTFail("expected bluetoothUnavailable, got \(result)")
            }
            XCTAssertEqual(message, "Bluetooth is powered off")
        }
        XCTAssertEqual(delegate.pendingNotificationCount, 0)
        guard case .unexpected = delegate.withCallbacks({ $0.complete(.advertising) }) else {
            return XCTFail("no request is left waiting")
        }
    }

    func testRemovingOneCharacteristicsNotificationsKeepsTheOthers() {
        let delegate = BLEPeripheralDelegate(store: GATTStore())
        let other = PendingNotification(
            value: Data([2]),
            characteristic: CBMutableCharacteristic(
                type: CBUUID(string: "2A37"), properties: [.notify], value: nil, permissions: []))
        _ = delegate.submitNotification(notification()) { _ in false }
        _ = delegate.submitNotification(other) { _ in false }
        delegate.removeNotifications(for: try! BLEUUID(parsing: "00002A19-0000-1000-8000-00805F9B34FB"))
        XCTAssertEqual(delegate.pendingNotificationCount, 1)
        delegate.removeNotifications()
        XCTAssertEqual(delegate.pendingNotificationCount, 0)
    }

    func testPoweredOnKeepsPendingWaits() {
        let delegate = BLEPeripheralDelegate(store: GATTStore())
        var lostState: CBManagerState?
        delegate.onLeftPoweredOn = { lostState = $0 }
        let results = Results()
        pendingRequest(delegate, .advertising, into: results)

        delegate.bluetoothStateChanged(.poweredOn)

        XCTAssertNil(lostState)
        XCTAssertTrue(results.all.isEmpty)
        guard case .waiter(let waiter) = delegate.withCallbacks({ $0.complete(.advertising) }) else {
            return XCTFail("the advertising request is still waiting")
        }
        waiter(.success(()))
        XCTAssertEqual(results.all.count, 1)
    }
}
