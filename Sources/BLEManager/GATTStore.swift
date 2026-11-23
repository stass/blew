import Foundation
import CoreBluetooth

/// Thread-safe store for characteristic values and central subscriber tracking.
///
/// `BLEPeripheralDelegate` accesses this from the peripheral manager's dispatch
/// queue (to respond to read/write requests). `BLEPeripheral` accesses it from
/// arbitrary threads when updating values. All access is guarded by `NSLock`.
/// Both tables are keyed by `BLEUUID`, so every spelling of a UUID finds one
/// entry.
final class GATTStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BLEUUID: Data] = [:]
    private var subscribers: [BLEUUID: [CBCentral]] = [:]

    // MARK: - Values

    func getValue(for characteristic: BLEUUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[characteristic]
    }

    func setValue(_ data: Data, for characteristic: BLEUUID) {
        lock.lock()
        defer { lock.unlock() }
        values[characteristic] = data
    }

    func allValues() -> [BLEUUID: Data] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    // MARK: - Subscribers

    func subscriberList(for characteristic: BLEUUID) -> [CBCentral] {
        lock.lock()
        defer { lock.unlock() }
        return subscribers[characteristic] ?? []
    }

    func addSubscriber(_ central: CBCentral, for characteristic: BLEUUID) {
        lock.lock()
        defer { lock.unlock() }
        var list = subscribers[characteristic] ?? []
        if !list.contains(where: { $0.identifier == central.identifier }) {
            list.append(central)
        }
        subscribers[characteristic] = list
    }

    func removeSubscriber(_ central: CBCentral, for characteristic: BLEUUID) {
        lock.lock()
        defer { lock.unlock() }
        subscribers[characteristic] = (subscribers[characteristic] ?? []).filter {
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
}
