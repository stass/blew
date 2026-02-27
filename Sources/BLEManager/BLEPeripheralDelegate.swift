import Foundation
import CoreBluetooth

/// CoreBluetooth peripheral manager delegate.
///
/// Read and write requests are answered synchronously within the callback
/// (required by CoreBluetooth). Events are emitted to `eventContinuation`
/// after responding, for logging and UI.
final class BLEPeripheralDelegate: NSObject, @unchecked Sendable {
    let store: GATTStore
    private let lock = NSLock()

    // One-shot continuation for the first poweredOn state transition.
    // Set by BLEPeripheral when it needs to wait for the manager to power on.
    private var stateContinuation: CheckedContinuation<Void, Error>?
    private var advertisingContinuation: CheckedContinuation<Void, Error>?
    private var pendingServiceContinuations: [String: CheckedContinuation<Void, Error>] = [:]

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

    func setStateContinuation(_ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        stateContinuation = cont
        lock.unlock()
    }

    func setAdvertisingContinuation(_ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        advertisingContinuation = cont
        lock.unlock()
    }

    func setServiceContinuation(uuid: String, _ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        pendingServiceContinuations[uuid.uppercased()] = cont
        lock.unlock()
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
        emitEvent(.stateChanged(peripheral.state))

        lock.lock()
        let cont = stateContinuation
        if peripheral.state == .poweredOn {
            stateContinuation = nil
        }
        lock.unlock()

        if peripheral.state == .poweredOn {
            cont?.resume()
        } else if peripheral.state == .poweredOff || peripheral.state == .unauthorized {
            let msg: String
            switch peripheral.state {
            case .poweredOff: msg = "Bluetooth is powered off"
            case .unauthorized: msg = "Bluetooth access unauthorized"
            case .unsupported: msg = "Bluetooth is not supported"
            default: msg = "Bluetooth state: \(peripheral.state.rawValue)"
            }
            cont?.resume(throwing: BLEError.peripheralUnavailable(msg))
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        emitEvent(.advertisingStarted(error: error?.localizedDescription))

        lock.lock()
        let cont = advertisingContinuation
        advertisingContinuation = nil
        lock.unlock()

        if let error = error {
            cont?.resume(throwing: BLEError.advertisingFailed(error.localizedDescription))
        } else {
            cont?.resume()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        let uuid = service.uuid.uuidString
        emitEvent(.serviceAdded(uuid: uuid, error: error?.localizedDescription))

        lock.lock()
        let cont = pendingServiceContinuations.removeValue(forKey: uuid.uppercased())
        lock.unlock()

        if let error = error {
            cont?.resume(throwing: BLEError.serviceRegistrationFailed(error.localizedDescription))
        } else {
            cont?.resume()
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        let uuid = characteristic.uuid.uuidString
        store.addSubscriber(central, for: uuid)
        emitEvent(.subscribed(centralId: central.identifier.uuidString, characteristicUUID: uuid))
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        let uuid = characteristic.uuid.uuidString
        store.removeSubscriber(central, for: uuid)
        emitEvent(.unsubscribed(centralId: central.identifier.uuidString, characteristicUUID: uuid))
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveRead request: CBATTRequest
    ) {
        let uuid = request.characteristic.uuid.uuidString
        let value = store.getValue(for: uuid) ?? Data()
        request.value = value.count > request.offset ? Data(value[request.offset...]) : Data()
        peripheral.respond(to: request, withResult: .success)
        emitEvent(.readRequest(centralId: request.central.identifier.uuidString, characteristicUUID: uuid))
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            let uuid = request.characteristic.uuid.uuidString
            let value = request.value ?? Data()
            store.setValue(value, for: uuid)
            emitEvent(.writeRequest(
                centralId: request.central.identifier.uuidString,
                characteristicUUID: uuid,
                value: value
            ))
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }
}
