import Foundation
@preconcurrency import CoreBluetooth

/// Public facade for BLE peripheral (GATT server) operations.
///
/// Owns the `CBPeripheralManager`, delegate, and value store.
/// All CoreBluetooth calls are serialised onto `blew.pm`.
///
/// `configure` and `startAdvertising` wait for a CoreBluetooth callback
/// through `request(_:issue:onSuccess:onCancel:)`: the wait ends with the
/// callback, with the Bluetooth state error when Bluetooth leaves
/// poweredOn, or with `CancellationError` when the calling task is
/// cancelled. A cancelled call undoes its request on `blew.pm` (stops
/// advertising, removes the services), so a callback that arrives after the
/// caller gave up cannot leave the Mac advertising.
public final class BLEPeripheral: @unchecked Sendable {
    public static let shared = BLEPeripheral()

    private let pmQueue = DispatchQueue(label: "blew.pm", qos: .userInitiated)
    private let store: GATTStore
    let delegate: BLEPeripheralDelegate
    private var peripheralManager: CBPeripheralManager!

    // State (guarded by stateLock). Changed on `blew.pm` when a request
    // succeeds, is cancelled, or Bluetooth leaves poweredOn, and by
    // `configure` and `stopAdvertising`.
    private let stateLock = NSLock()
    private var _isAdvertising = false
    private var _advertisedName: String?
    private var registeredCharacteristics: [BLEUUID: CBMutableCharacteristic] = [:]
    private var registeredServices: [CBMutableService] = []

    private init() {
        self.store = GATTStore()
        self.delegate = BLEPeripheralDelegate(store: store)
        delegate.onLeftPoweredOn = { [unowned self] _ in
            // Advertising has stopped and the services are gone; a new
            // `periph adv` publishes them again.
            self.clearPublishedState()
        }
        self.peripheralManager = CBPeripheralManager(delegate: delegate, queue: pmQueue)
    }

    // MARK: - Public API

    /// Configure GATT services and register them with the peripheral manager.
    /// Must be called before `startAdvertising`. Replaces any previously configured services.
    /// Cancelling the calling task removes every service.
    public func configure(services: [ServiceDefinition]) async throws {
        try await waitForPoweredOn(timeout: 5.0)

        // Remove previously added services
        pmQueue.sync {
            self.peripheralManager.removeAllServices()
            self.clearServices()
        }

        store.reset()

        for svcDef in services {
            // Services with no characteristics are advertise-only: they don't need
            // to be registered with the peripheral manager (and CoreBluetooth will
            // reject adding a standard Bluetooth SIG service UUID with no GATT content).
            guard !svcDef.characteristics.isEmpty else { continue }

            let mutableChars = buildMutableCharacteristics(from: svcDef.characteristics)
            let mutableService = CBMutableService(type: svcDef.uuid.cbuuid, primary: svcDef.primary)
            mutableService.characteristics = mutableChars.map { $0.char }

            try await request(
                .addService(svcDef.uuid),
                issue: { self.peripheralManager.add(mutableService) },
                onSuccess: {
                    self.stateLock.withLock {
                        for mc in mutableChars {
                            self.registeredCharacteristics[mc.uuid] = mc.char
                        }
                        self.registeredServices.append(mutableService)
                    }
                },
                onCancel: {
                    self.peripheralManager.removeAllServices()
                    self.clearServices()
                })
        }
    }

    /// Start advertising with the given local name and service UUIDs.
    /// Cancelling the calling task stops advertising.
    ///
    /// CoreBluetooth only allows `CBAdvertisementDataLocalNameKey` and
    /// `CBAdvertisementDataServiceUUIDsKey` in the advertisement dictionary.
    /// Manufacturer data and other ADV fields are not supported.
    public func startAdvertising(name: String, serviceUUIDs: [BLEUUID]) async throws {
        try await waitForPoweredOn(timeout: 5.0)

        let advertisedUUIDs = serviceUUIDs.map(\.cbuuid)

        try await request(
            .advertising,
            issue: {
                var adData: [String: Any] = [CBAdvertisementDataLocalNameKey: name]
                if !advertisedUUIDs.isEmpty {
                    adData[CBAdvertisementDataServiceUUIDsKey] = advertisedUUIDs
                }
                self.peripheralManager.startAdvertising(adData)
            },
            onSuccess: {
                self.stateLock.withLock {
                    self._isAdvertising = true
                    self._advertisedName = name
                }
            },
            onCancel: {
                self.peripheralManager.stopAdvertising()
                self.stateLock.withLock { self._isAdvertising = false }
            })
    }

    /// Stop advertising. Does not remove registered services.
    public func stopAdvertising() {
        pmQueue.async {
            self.peripheralManager.stopAdvertising()
        }
        stateLock.lock()
        _isAdvertising = false
        stateLock.unlock()
    }

    /// Update the stored value of a characteristic and notify every
    /// subscribed central. While CoreBluetooth's transmit queue is full the
    /// notification waits in a queue of at most
    /// `BLEPeripheralDelegate.notificationQueueCapacity`; a notification
    /// that finds that queue full is an error and leaves the value unchanged.
    @discardableResult
    public func updateValue(_ data: Data, forCharacteristic uuid: BLEUUID) throws -> ValueUpdate {
        try pmQueue.sync {
            let state = peripheralManager.state
            guard state == .poweredOn else { throw BLEError.unavailable(state) }
            guard let mutableChar = stateLock.withLock({ registeredCharacteristics[uuid] }) else {
                throw BLEError.characteristicNotFound(uuid.string)
            }
            guard !store.subscriberList(for: uuid).isEmpty else {
                store.setValue(data, for: uuid)
                return .stored
            }
            let outcome = delegate.submitNotification(
                PendingNotification(value: data, characteristic: mutableChar)
            ) { notification in
                self.peripheralManager.updateValue(
                    notification.value, for: notification.characteristic, onSubscribedCentrals: nil)
            }
            switch outcome {
            case .sent:
                store.setValue(data, for: uuid)
                return .notified
            case .queued(let pending):
                store.setValue(data, for: uuid)
                return .queued(pending: pending)
            case .full:
                throw BLEError.operationFailed(
                    "notification not sent: \(BLEPeripheralDelegate.notificationQueueCapacity) notifications "
                        + "are already waiting for the Bluetooth transmit queue")
            }
        }
    }

    /// Returns an `AsyncStream` of peripheral events (read/write requests, subscriptions, etc.).
    /// Only one stream is active at a time; calling this again replaces the previous stream.
    public func events() -> AsyncStream<PeripheralEvent> {
        AsyncStream<PeripheralEvent> { continuation in
            delegate.setEventContinuation(continuation)
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.delegate.setEventContinuation(nil)
            }
        }
    }

    /// Synchronous snapshot of peripheral state for status display.
    public func peripheralStatus() -> PeripheralStatus {
        stateLock.lock()
        let advertising = _isAdvertising
        let name = _advertisedName
        let svcCount = registeredServices.count
        let charCount = registeredCharacteristics.count
        stateLock.unlock()
        let subCount = store.totalSubscriberCount()
        return PeripheralStatus(
            isAdvertising: advertising,
            advertisedName: name,
            serviceCount: svcCount,
            characteristicCount: charCount,
            subscriberCount: subCount
        )
    }

    public func isAdvertising() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isAdvertising
    }

    /// The Bluetooth state CoreBluetooth reports.
    public func bluetoothState() -> CBManagerState {
        pmQueue.sync { peripheralManager.state }
    }

    /// Return all registered characteristic UUIDs (for REPL tab completion).
    public func knownCharacteristicUUIDs() -> [BLEUUID] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(registeredCharacteristics.keys)
    }

    // MARK: - Private helpers

    /// No service is published, so nothing is left to notify. Call on `blew.pm`.
    private func clearServices() {
        delegate.removeNotifications()
        stateLock.withLock {
            registeredCharacteristics = [:]
            registeredServices = []
        }
    }

    /// Nothing is advertised or published.
    private func clearPublishedState() {
        clearServices()
        stateLock.withLock {
            _isAdvertising = false
            _advertisedName = nil
        }
    }

    /// Issue one CoreBluetooth request on `blew.pm` and wait for the callback
    /// that answers it (see `PendingCallbacks`).
    ///
    /// - `issue` makes the request; it runs on `blew.pm`, and only while
    ///   Bluetooth is poweredOn (otherwise the wait fails with its state).
    /// - `onSuccess` runs on `blew.pm` when the callback reports success,
    ///   before the caller resumes.
    /// - `onCancel` undoes the request; it runs on `blew.pm` whenever the
    ///   calling task is cancelled during the wait (after `issue` if the
    ///   request was issued), including after a success the caller has not
    ///   yet seen. It also runs when the request was never issued, so it
    ///   stops advertising or removes services an earlier call set up.
    ///
    /// A cancellation that lands in the last instant of the wait, after its
    /// final check, still queues the undo but lets the call return success;
    /// the canceller (`waitInterruptible`) reports failure either way.
    private func request(
        _ key: PeripheralRequest,
        issue: @escaping @Sendable () -> Void,
        onSuccess: @escaping @Sendable () -> Void,
        onCancel undo: @escaping @Sendable () -> Void
    ) async throws {
        let ticket = delegate.withCallbacks { $0.makeTicket() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let waiter: PeripheralWaiter = { result in
                    if case .success = result { onSuccess() }
                    cont.resume(with: result)
                }
                guard delegate.withCallbacks({ $0.add(ticket, waiter) }) else {
                    cont.resume(throwing: CancellationError())
                    return
                }
                pmQueue.async {
                    let state = self.peripheralManager.state
                    guard state == .poweredOn else {
                        let waiter = self.delegate.withCallbacks { $0.cancel(ticket) }
                        waiter?(.failure(BLEError.unavailable(state)))
                        return
                    }
                    guard self.delegate.withCallbacks({ $0.issue(ticket, as: key) }) else { return }
                    issue()
                }
            }
            // Cancelled after the success callback: the cancellation
            // handler has queued the undo, so report the call as cancelled.
            try Task.checkCancellation()
        } onCancel: {
            let waiter = delegate.withCallbacks { $0.cancel(ticket) }
            waiter?(.failure(CancellationError()))
            pmQueue.async(execute: undo)
        }
    }

    private struct MutableCharEntry {
        let uuid: BLEUUID
        let char: CBMutableCharacteristic
    }

    private func buildMutableCharacteristics(
        from defs: [CharacteristicDefinition]
    ) -> [MutableCharEntry] {
        defs.map { def in
            let props = cbProperties(from: def.properties)
            let perms = cbPermissions(from: def.properties)
            let mutableChar = CBMutableCharacteristic(
                type: def.uuid.cbuuid,
                properties: props,
                value: nil,
                permissions: perms
            )
            return MutableCharEntry(uuid: def.uuid, char: mutableChar)
        }
    }

    private func cbProperties(from props: [CharacteristicProperty]) -> CBCharacteristicProperties {
        var result: CBCharacteristicProperties = []
        for p in props {
            switch p {
            case .read:                 result.insert(.read)
            case .write:                result.insert(.write)
            case .writeWithoutResponse: result.insert(.writeWithoutResponse)
            case .notify:               result.insert(.notify)
            case .indicate:             result.insert(.indicate)
            }
        }
        return result
    }

    private func cbPermissions(from props: [CharacteristicProperty]) -> CBAttributePermissions {
        var result: CBAttributePermissions = []
        if props.contains(.read) { result.insert(.readable) }
        if props.contains(.write) || props.contains(.writeWithoutResponse) {
            result.insert(.writeable)
        }
        return result
    }

    /// Poll the state until poweredOn. A state that will not change by
    /// itself fails at once; the wait is cancellable and has a deadline.
    private func waitForPoweredOn(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state: CBManagerState = pmQueue.sync { peripheralManager.state }
            if state == .poweredOn { return }
            if let error = BLEError.persistentlyUnavailable(state) { throw error }
            if Date() > deadline {
                throw BLEError.peripheralUnavailable("Timed out waiting for Bluetooth to power on")
            }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
    }

}
