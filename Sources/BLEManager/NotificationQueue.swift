import Foundation
@preconcurrency import CoreBluetooth

/// Notifications waiting for room in CoreBluetooth's transmit queue.
///
/// `CBPeripheralManager.updateValue(_:for:onSubscribedCentrals:)` returns
/// false when its transmit queue is full and later calls
/// `peripheralManagerIsReady(toUpdateSubscribers:)`. A notification it
/// refuses is kept here and sent, in order, once it is ready. Once one is
/// waiting, later ones queue behind it, so subscribers see the values in
/// the order they were set. The queue is bounded: a notification that
/// finds it full is rejected, and the caller reports an error rather than
/// dropping it. Pure value type; the `send` closure is the CoreBluetooth
/// call, and `BLEPeripheralDelegate` owns the one instance on `blew.pm`.
struct NotificationQueue<Item> {
    enum Outcome: Equatable {
        /// CoreBluetooth took the notification.
        case sent
        /// The notification waits in this queue, `pending` long.
        case queued(pending: Int)
        /// The queue is full; the notification was not taken.
        case full
    }

    let capacity: Int
    private var pending: [Item] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    var pendingCount: Int { pending.count }

    mutating func submit(_ item: Item, send: (Item) -> Bool) -> Outcome {
        if pending.isEmpty && send(item) { return .sent }
        guard pending.count < capacity else { return .full }
        pending.append(item)
        return .queued(pending: pending.count)
    }

    /// Send queued notifications in order until CoreBluetooth refuses one
    /// again. Returns how many were sent.
    mutating func drain(send: (Item) -> Bool) -> Int {
        var sent = 0
        while let first = pending.first, send(first) {
            pending.removeFirst()
            sent += 1
        }
        return sent
    }

    mutating func removeAll(where shouldRemove: (Item) -> Bool = { _ in true }) {
        pending.removeAll(where: shouldRemove)
    }
}

/// A value to notify to every subscriber of `characteristic`.
struct PendingNotification {
    let value: Data
    let characteristic: CBMutableCharacteristic
}

/// What `BLEPeripheral.updateValue` did with a new value.
public enum ValueUpdate: Sendable, Equatable {
    /// Stored; no central is subscribed, so nothing was notified.
    case stored
    /// Stored and handed to CoreBluetooth for every subscriber.
    case notified
    /// Stored; the notification waits for CoreBluetooth's transmit queue,
    /// `pending` notifications long.
    case queued(pending: Int)
}
