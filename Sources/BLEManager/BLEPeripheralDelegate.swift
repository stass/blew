import Foundation
import CoreBluetooth

/// A CoreBluetooth request whose callback a caller waits for, and what its
/// undo does to that callback (measured on a radio: TESTS.md, "Cancelled
/// peripheral requests").
enum PeripheralRequest: Hashable {
    /// `startAdvertising`, answered by `didStartAdvertising`. CoreBluetooth
    /// still answers it after `stopAdvertising` undoes it, so a cancelled one
    /// keeps its place in the FIFO and takes that answer.
    case advertising
    /// `add(_:)`, answered by `didAdd`. CoreBluetooth did not answer an add
    /// that `removeAllServices` undid before answering it, so removing the
    /// services ends every add issued before it (`servicesRemoved`).
    case addService(BLEUUID)
}

/// Resumes one caller of `BLEPeripheral` with the callback's result. Called
/// once, on `blew.pm` for a callback and on any thread for a cancellation.
typealias PeripheralWaiter = (Result<Void, Error>) -> Void

/// CoreBluetooth peripheral manager delegate.
///
/// Read and write requests are answered synchronously within the callback
/// (required by CoreBluetooth). Events are emitted to `eventContinuation`
/// after responding, for logging and UI.
///
/// Ownership: `callbacks` and `eventContinuation` are guarded by `lock`;
/// `notifications` is confined to `blew.pm` (the delegate queue, and
/// `BLEPeripheral`'s `pmQueue.sync` blocks).
final class BLEPeripheralDelegate: NSObject, @unchecked Sendable {
    let store: GATTStore
    private let lock = NSLock()

    private var callbacks = PendingCallbacks<PeripheralRequest, PeripheralWaiter>()

    /// At most this many notifications wait for CoreBluetooth's transmit
    /// queue; `BLEPeripheral.updateValue` reports an error past it.
    static let notificationQueueCapacity = 64
    private var notifications = NotificationQueue<PendingNotification>(capacity: notificationQueueCapacity)

    /// Called on `blew.pm` when Bluetooth reports any state but poweredOn,
    /// after pending waits have been failed. Set once, before the peripheral
    /// manager exists.
    var onLeftPoweredOn: ((CBManagerState) -> Void)?

    // AsyncStream continuation for ongoing event delivery to the CLI layer.
    // Access only from `emitEvent` (which guards under lock).
    private var eventContinuation: AsyncStream<PeripheralEvent>.Continuation?

    init(store: GATTStore) {
        self.store = store
    }

    // MARK: - Wiring

    func setEventContinuation(_ cont: AsyncStream<PeripheralEvent>.Continuation?) {
        lock.lock()
        eventContinuation = cont
        lock.unlock()
    }

    /// Run `body` on the pending callbacks under the lock. Resume any waiter
    /// it returns after this returns, outside the lock.
    func withCallbacks<R>(_ body: (inout PendingCallbacks<PeripheralRequest, PeripheralWaiter>) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&callbacks)
    }

    /// Notify `notification`, or queue it while the transmit queue is full.
    /// Call on `blew.pm`; `send` is the CoreBluetooth `updateValue` call.
    func submitNotification(
        _ notification: PendingNotification, send: (PendingNotification) -> Bool
    ) -> NotificationQueue<PendingNotification>.Outcome {
        notifications.submit(notification, send: send)
    }

    /// Call on `blew.pm`.
    var pendingNotificationCount: Int { notifications.pendingCount }

    /// Drop queued notifications: every one when the services are removed,
    /// or those of a characteristic whose last subscriber left (a later
    /// subscriber must not get a value older than the stored one). Call on
    /// `blew.pm`.
    func removeNotifications(for characteristic: BLEUUID? = nil) {
        notifications.removeAll { notification in
            characteristic.map { BLEUUID(notification.characteristic.uuid) == $0 } ?? true
        }
    }

    /// Bluetooth reported `state`. Below poweredOn, CoreBluetooth stops
    /// advertising, invalidates the published services and drops every
    /// central (CBPeripheralManagerDelegate, `peripheralManagerDidUpdateState`),
    /// so nothing in flight will be answered: fail every pending wait with
    /// the state's error, drop queued notifications and subscribers, and let
    /// the owner clear its advertising state. The event is emitted last, so
    /// a listener that sees it also sees the cleared state. Call on `blew.pm`.
    func bluetoothStateChanged(_ state: CBManagerState) {
        if state != .poweredOn {
            let waiters = withCallbacks { $0.removeAll() }
            notifications.removeAll()
            store.removeAllSubscribers()
            onLeftPoweredOn?(state)
            let error = BLEError.unavailable(state)
            for waiter in waiters { waiter(.failure(error)) }
        }
        emitEvent(.stateChanged(state))
    }

    /// `removeAllServices` was called. CoreBluetooth sent no `didAdd` for an
    /// add it removed this way before answering it (measured with the add
    /// removed at once, TESTS.md "Cancelled peripheral requests"), so drop
    /// the adds still in flight (a cancelled one would otherwise take the
    /// next add's `didAdd`) and fail the ones still waiting. Call on
    /// `blew.pm`, right after `removeAllServices`. A `didAdd` already queued
    /// on `blew.pm` runs before this and completes its own entry; an add
    /// issued after this is queued after the drop.
    func servicesRemoved() {
        let waiters = withCallbacks { callbacks in
            callbacks.discardIssued { request in
                if case .addService = request { return true }
                return false
            }
        }
        let error = BLEError.serviceRegistrationFailed("the services were removed before the add completed")
        for waiter in waiters { waiter(.failure(error)) }
    }

    // MARK: - Private helpers

    private func emitEvent(_ event: PeripheralEvent) {
        lock.lock()
        let cont = eventContinuation
        lock.unlock()
        cont?.yield(event)
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEPeripheralDelegate: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        bluetoothStateChanged(peripheral.state)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        emitEvent(.advertisingStarted(error: error?.localizedDescription))

        switch withCallbacks({ $0.complete(.advertising) }) {
        case .waiter(let waiter):
            waiter(error.map { .failure(BLEError.advertisingFailed($0.localizedDescription)) } ?? .success(()))
        case .abandoned(let laterRequests):
            // The command that asked for this gave up; its cancellation
            // queued a stop, but advertising that started after it must not
            // outlive it. A later start owns advertising, so leave it alone.
            if error == nil && laterRequests == 0 {
                peripheral.stopAdvertising()
            }
        case .unexpected:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        let uuid = BLEUUID(service.uuid)
        emitEvent(.serviceAdded(uuid: uuid.string, error: error?.localizedDescription))

        // An abandoned add needs nothing here: its cancellation queued
        // `removeAllServices` after the add, and this `didAdd` was queued on
        // `blew.pm` before that ran (see `servicesRemoved`).
        if case .waiter(let waiter) = withCallbacks({ $0.complete(.addService(uuid)) }) {
            waiter(error.map { .failure(BLEError.serviceRegistrationFailed($0.localizedDescription)) } ?? .success(()))
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        _ = notifications.drain { notification in
            peripheral.updateValue(notification.value, for: notification.characteristic, onSubscribedCentrals: nil)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        let uuid = BLEUUID(characteristic.uuid)
        store.addSubscriber(central, for: uuid)
        emitEvent(.subscribed(centralId: central.identifier.uuidString, characteristicUUID: uuid.string))
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        let uuid = BLEUUID(characteristic.uuid)
        store.removeSubscriber(central, for: uuid)
        if store.subscriberList(for: uuid).isEmpty {
            removeNotifications(for: uuid)
        }
        emitEvent(.unsubscribed(centralId: central.identifier.uuidString, characteristicUUID: uuid.string))
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        let uuid = BLEUUID(request.characteristic.uuid)
        switch store.read(uuid, at: request.offset) {
        case .success(let value):
            request.value = value
            peripheral.respond(to: request, withResult: .success)
        case .failure(let code):
            peripheral.respond(to: request, withResult: code)
        }
        emitEvent(.readRequest(centralId: request.central.identifier.uuidString, characteristicUUID: uuid.string))
    }

    /// One Write Request, or every fragment of a long write on Execute
    /// Write. CoreBluetooth takes one response for the whole array, given
    /// with its first request: success only if every write applies.
    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        guard let first = requests.first else { return }
        let writes = requests.map {
            ATTWrite(characteristic: BLEUUID($0.characteristic.uuid), offset: $0.offset, value: $0.value ?? Data())
        }
        switch store.write(writes) {
        case .success(let written):
            peripheral.respond(to: first, withResult: .success)
            var reported = Set<BLEUUID>()
            for (request, write) in zip(requests, writes) where reported.insert(write.characteristic).inserted {
                emitEvent(.writeRequest(
                    centralId: request.central.identifier.uuidString,
                    characteristicUUID: write.characteristic.string,
                    value: written[write.characteristic] ?? Data()
                ))
            }
        case .failure(let code):
            peripheral.respond(to: first, withResult: code)
        }
    }
}
