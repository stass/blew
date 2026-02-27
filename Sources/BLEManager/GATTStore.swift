import Foundation
import CoreBluetooth

/// Thread-safe store for characteristic values and central subscriber tracking.
///
/// `BLEPeripheralDelegate` accesses this from the peripheral manager's dispatch
/// queue (to respond to read/write requests). `BLEPeripheral` accesses it from
/// arbitrary threads when updating values. All access is guarded by `NSLock`.
final class GATTStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var subscribers: [String: [CBCentral]] = [:]

    // MARK: - Values

    func getValue(for characteristicUUID: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[normalise(characteristicUUID)]
    }

    func setValue(_ data: Data, for characteristicUUID: String) {
        lock.lock()
        defer { lock.unlock() }
        values[normalise(characteristicUUID)] = data
    }

    func allValues() -> [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    // MARK: - Subscribers

    func subscriberList(for characteristicUUID: String) -> [CBCentral] {
        lock.lock()
        defer { lock.unlock() }
        return subscribers[normalise(characteristicUUID)] ?? []
    }

    func addSubscriber(_ central: CBCentral, for characteristicUUID: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = normalise(characteristicUUID)
        var list = subscribers[key] ?? []
        if !list.contains(where: { $0.identifier == central.identifier }) {
            list.append(central)
        }
        subscribers[key] = list
    }

    func removeSubscriber(_ central: CBCentral, for characteristicUUID: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = normalise(characteristicUUID)
        subscribers[key] = (subscribers[key] ?? []).filter {
            $0.identifier != central.identifier
        }
    }

    func removeAllSubscribers(for central: CBCentral) {
        lock.lock()
        defer { lock.unlock() }
        for key in subscribers.keys {
            subscribers[key] = (subscribers[key] ?? []).filter {
                $0.identifier != central.identifier
            }
        }
    }

    func totalSubscriberCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<UUID>()
        for list in subscribers.values {
            for c in list { seen.insert(c.identifier) }
        }
        return seen.count
    }

    // MARK: - Reset

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        values = [:]
        subscribers = [:]
    }

    // MARK: - Helpers

    private func normalise(_ uuid: String) -> String {
        uuid.uppercased()
    }
}
