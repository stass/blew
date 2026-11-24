import Foundation
import CoreBluetooth

/// The answer to a read or write request from a remote central: the
/// result, or the ATT error `respond(to:withResult:)` sends back.
enum ATTOutcome<Value: Equatable>: Equatable {
    case success(Value)
    case failure(CBATTError.Code)
}

/// One write from a remote central. A Write Request arrives as one write at
/// offset 0; a long (prepared) write arrives, on Execute Write, as one
/// write per Prepare Write fragment, each at its offset.
struct ATTWrite: Equatable {
    let characteristic: BLEUUID
    let offset: Int
    let value: Data
}

/// Thread-safe store for characteristic values and central subscriber tracking.
///
/// `BLEPeripheralDelegate` accesses this from the peripheral manager's dispatch
/// queue (to respond to read/write requests). `BLEPeripheral` accesses it from
/// arbitrary threads when updating values. All access is guarded by `NSLock`.
/// Both tables are keyed by `BLEUUID`, so every spelling of a UUID finds one
/// entry.
///
/// Requests from a remote central are untrusted. `read(_:at:)` and
/// `apply(_:to:)` decide them as pure functions: an offset past the end of
/// the value is Invalid Offset, and a value longer than the ATT maximum is
/// Invalid Attribute Value Length (Core spec Vol 3 Part F 3.2.9, 3.4.4.5,
/// 3.4.6.3), so a central cannot grow a value without bound.
final class GATTStore: @unchecked Sendable {
    /// The longest attribute value ATT allows (Core spec Vol 3 Part F 3.2.9).
    static let maxValueLength = 512

    private let lock = NSLock()
    private var values: [BLEUUID: Data] = [:]
    private var subscribers: [BLEUUID: [CBCentral]] = [:]

    // MARK: - Requests from a remote central

    /// The part of `value` a Read (offset 0) or Read Blob request at
    /// `offset` returns: empty at the end of the value, Invalid Offset past it.
    static func read(_ value: Data, at offset: Int) -> ATTOutcome<Data> {
        guard offset >= 0, offset <= value.count else { return .failure(.invalidOffset) }
        return .success(Data(value.dropFirst(offset)))
    }

    /// Apply the writes of one request, in order, to `values`. A write at
    /// offset n keeps the first n bytes of the value and replaces the rest,
    /// so a Write Request replaces the value and the fragments of a long
    /// write assemble it. All or nothing: the first write that fails rejects
    /// the request. Returns the new value of each written characteristic.
    static func apply(_ writes: [ATTWrite], to values: [BLEUUID: Data]) -> ATTOutcome<[BLEUUID: Data]> {
        var written: [BLEUUID: Data] = [:]
        for write in writes {
            let current = written[write.characteristic] ?? values[write.characteristic] ?? Data()
            guard write.offset >= 0, write.offset <= current.count else {
                return .failure(.invalidOffset)
            }
            guard write.offset <= maxValueLength,
                  write.value.count <= maxValueLength - write.offset else {
                return .failure(.invalidAttributeValueLength)
            }
            written[write.characteristic] = Data(current.prefix(write.offset)) + write.value
        }
        return .success(written)
    }

    func read(_ characteristic: BLEUUID, at offset: Int) -> ATTOutcome<Data> {
        lock.lock()
        defer { lock.unlock() }
        return Self.read(values[characteristic] ?? Data(), at: offset)
    }

    /// Apply one request's writes atomically: either every written value is
    /// stored or, on an ATT error, none is.
    func write(_ writes: [ATTWrite]) -> ATTOutcome<[BLEUUID: Data]> {
        lock.lock()
        defer { lock.unlock() }
        let outcome = Self.apply(writes, to: values)
        if case .success(let written) = outcome {
            values.merge(written) { _, new in new }
        }
        return outcome
    }

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

    /// Bluetooth left poweredOn: every central is gone.
    func removeAllSubscribers() {
        lock.lock()
        defer { lock.unlock() }
        subscribers = [:]
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
