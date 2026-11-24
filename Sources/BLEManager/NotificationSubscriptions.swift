import Foundation

/// The subscribers of each characteristic's notifications, and whether the
/// device has them on: the one owner of a characteristic's notification
/// state. Notifications are turned on for the first subscriber and off when
/// the last one leaves; each subscriber has its own stream, and every
/// notification goes to all of them.
///
/// At most one `setNotifyValue` call is in flight per characteristic. When
/// its acknowledgement arrives, the next call is made only if the
/// subscribers now want the other state. So each acknowledgement answers
/// the call before it, `setNotifyValue(true)` is never made while
/// notifications are on, and `setNotifyValue(false)` only after the device
/// confirmed them on.
///
/// A subscriber's stream is registered when it is added, before
/// notifications are turned on, so a notification that comes right after
/// the confirmation reaches it. Its confirmation resumes once the device has
/// confirmed notifications on (at once when they already are) and fails
/// with the device's error otherwise.
///
/// A subscriber moves through these steps, each under the owner's lock:
/// `makeID` reserves its ID; `add` registers it (or `refuse` turns it away;
/// either reports `CancellationError` when `remove` came first); `remove`
/// takes it out when its wait is cancelled or its stream ends. Pure value
/// type; `BLEEventProcessor` owns one under its lock and runs the returned
/// effects after unlocking.
struct NotificationSubscriptions {
    typealias Stream = NotificationSink
    typealias Confirmation = CheckedContinuation<Void, Error>
    typealias Effects = [() -> Void]

    struct ID: Hashable, Sendable {
        fileprivate let value: Int
    }

    private struct Subscriber {
        let id: Int
        let stream: Stream
        /// Waiting for notifications to be confirmed on; nil once resumed.
        var confirmation: Confirmation?
    }

    private struct Characteristic {
        /// Makes the CoreBluetooth call for this characteristic.
        let setNotify: @Sendable (Bool) -> Void
        /// In the order they were added. While notifications are not
        /// confirmed on, every subscriber is still waiting for them.
        var subscribers: [Subscriber] = []
        /// What the device last confirmed.
        var isOn = false
        /// The value of the `setNotifyValue` call in flight, if any.
        var pending: Bool?

        var isIdle: Bool { subscribers.isEmpty && !isOn && pending == nil }
    }

    /// An ID made and not yet added or refused.
    private enum Reservation {
        case waiting
        /// `remove` came first: the subscriber is turned away when it comes.
        case removedFirst
    }

    private var nextID = 0
    private var reserved: [Int: Reservation] = [:]
    private var characteristics: [String: Characteristic] = [:]

    mutating func makeID() -> ID {
        nextID += 1
        reserved[nextID] = .waiting
        return ID(value: nextID)
    }

    /// Register a subscriber of `characteristic` with its stream, and turn
    /// notifications on if they are not. `setNotify` makes the
    /// CoreBluetooth call; the first subscriber's is kept for the
    /// characteristic until it is idle again.
    mutating func add(_ id: ID, to characteristic: String, stream: Stream, confirmation: Confirmation,
                      setNotify: @escaping @Sendable (Bool) -> Void) -> Effects {
        guard case .waiting? = reserved.removeValue(forKey: id.value) else {
            return Self.fail(stream, confirmation, CancellationError())
        }
        var entry = characteristics[characteristic] ?? Characteristic(setNotify: setNotify)
        var effects: Effects = []
        if entry.isOn && entry.pending == nil {
            entry.subscribers.append(Subscriber(id: id.value, stream: stream, confirmation: nil))
            effects.append { confirmation.resume() }
        } else {
            entry.subscribers.append(Subscriber(id: id.value, stream: stream, confirmation: confirmation))
            effects += Self.reconcile(&entry)
        }
        characteristics[characteristic] = entry
        return effects
    }

    /// Turn the subscriber away with `error` without registering it.
    mutating func refuse(_ id: ID, stream: Stream, confirmation: Confirmation, _ error: Error) -> Effects {
        let removedFirst: Bool
        if case .removedFirst? = reserved.removeValue(forKey: id.value) { removedFirst = true } else { removedFirst = false }
        return Self.fail(stream, confirmation, removedFirst ? CancellationError() : error)
    }

    /// The subscriber leaves: its subscribe was cancelled or its stream
    /// ended. A confirmation still waiting fails with `CancellationError`,
    /// and the stream finishes with it (a no-op for one that already
    /// ended), also when the cancellation came after the confirmation.
    /// Notifications are turned off when it was the last. A no-op for a
    /// subscriber already gone.
    mutating func remove(_ id: ID) -> Effects {
        if reserved[id.value] != nil {
            reserved[id.value] = .removedFirst
            return []
        }
        for (characteristic, var entry) in characteristics {
            guard let index = entry.subscribers.firstIndex(where: { $0.id == id.value }) else { continue }
            let subscriber = entry.subscribers.remove(at: index)
            var effects = Self.fail(subscriber.stream, subscriber.confirmation, CancellationError())
            effects += Self.reconcile(&entry)
            characteristics[characteristic] = entry.isIdle ? nil : entry
            return effects
        }
        return []
    }

    /// The device acknowledged the `setNotifyValue` call in flight for
    /// `characteristic`, with `error` when it failed. An acknowledgement
    /// with no call in flight answers nothing and is dropped.
    mutating func acknowledge(_ characteristic: String, error: BLEError?) -> Effects {
        guard var entry = characteristics[characteristic], let asked = entry.pending else { return [] }
        entry.pending = nil
        var effects: Effects = []
        // Whether to make the next call when the subscribers want the other
        // state.
        var reconciles = true
        switch (asked, error) {
        case (true, nil):
            entry.isOn = true
        case (false, nil):
            entry.isOn = false
        case (true, let error?):
            // Every subscriber waits for this confirmation (none is confirmed
            // while notifications are off).
            entry.isOn = false
            for subscriber in entry.subscribers {
                effects += Self.fail(subscriber.stream, subscriber.confirmation, error)
            }
            entry.subscribers = []
        case (false, _?):
            // Turning them off failed, so they are still on. That is not
            // retried until a subscriber comes and leaves again; retrying
            // here could repeat forever.
            entry.isOn = true
            reconciles = false
        }
        if entry.isOn {
            for index in entry.subscribers.indices {
                guard let confirmation = entry.subscribers[index].confirmation else { continue }
                entry.subscribers[index].confirmation = nil
                effects.append { confirmation.resume() }
            }
        }
        if reconciles {
            effects += Self.reconcile(&entry)
        }
        characteristics[characteristic] = entry.isIdle ? nil : entry
        return effects
    }

    /// The streams of `characteristic`'s subscribers, also of those still
    /// waiting for their confirmation.
    func streams(of characteristic: String) -> [Stream] {
        characteristics[characteristic]?.subscribers.map(\.stream) ?? []
    }

    /// The number of characteristics with at least one subscriber.
    var subscribedCount: Int {
        characteristics.values.filter { !$0.subscribers.isEmpty }.count
    }

    /// The connection ended: every stream finishes with `error` and every
    /// waiting confirmation fails with it. Reserved IDs stay usable; their
    /// subscriber is checked against the connection when it is added.
    mutating func removeAll(_ error: Error) -> Effects {
        var effects: Effects = []
        for entry in characteristics.values {
            for subscriber in entry.subscribers {
                effects += Self.fail(subscriber.stream, subscriber.confirmation, error)
            }
        }
        characteristics = [:]
        return effects
    }

    /// Make the next `setNotifyValue` call when none is in flight and the
    /// subscribers want the other state.
    private static func reconcile(_ entry: inout Characteristic) -> Effects {
        guard entry.pending == nil else { return [] }
        let wanted = !entry.subscribers.isEmpty
        guard wanted != entry.isOn else { return [] }
        entry.pending = wanted
        let setNotify = entry.setNotify
        return [{ setNotify(wanted) }]
    }

    private static func fail(_ stream: Stream, _ confirmation: Confirmation?, _ error: Error) -> Effects {
        [{
            confirmation?.resume(throwing: error)
            stream.finish(throwing: error)
        }]
    }
}
