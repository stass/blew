import Foundation

/// Waiters for CoreBluetooth callbacks that each answer one request
/// (`add(_:)` answered by `didAdd`, `startAdvertising` by
/// `didStartAdvertising`).
///
/// CoreBluetooth answers the requests for one key in the order they were
/// made and carries no request identifier, so the waiters for a key form a
/// FIFO. A request cancelled after it was issued keeps its place as an
/// abandoned entry: the callback it still gets is recognised as its own
/// and does not resume the waiter of a later request.
///
/// A ticket moves through these states, each step under the owner's lock:
/// `makeTicket` reserves it; `add` attaches the waiter (or reports that the
/// ticket was cancelled first, so the request must not be issued); `issue`
/// queues it under its key just before the request goes to CoreBluetooth
/// (or reports that it was cancelled, so it must not go); `complete` takes
/// the oldest entry for a key when its callback arrives. `cancel` withdraws
/// the waiter at any step. Pure value type; `BLEPeripheralDelegate` owns
/// the one instance under its lock.
struct PendingCallbacks<Key: Hashable, Waiter> {
    struct Ticket: Hashable {
        fileprivate let id: Int
    }

    enum Completion {
        /// The callback answers a request whose waiter is still waiting.
        case waiter(Waiter)
        /// The callback answers a cancelled request; `laterRequests` more
        /// requests for the same key are still in flight.
        case abandoned(laterRequests: Int)
        /// No request for this key is in flight.
        case unexpected
    }

    private enum Unissued {
        case reserved
        case cancelled
        case waiting(Waiter)
    }

    private struct Entry {
        let id: Int
        var waiter: Waiter?
    }

    private var nextID = 0
    private var unissued: [Int: Unissued] = [:]
    private var issued: [Key: [Entry]] = [:]

    mutating func makeTicket() -> Ticket {
        nextID += 1
        unissued[nextID] = .reserved
        return Ticket(id: nextID)
    }

    /// Attach the waiter. False when the ticket was cancelled first: the
    /// request must not be issued, and the caller resumes the waiter itself.
    mutating func add(_ ticket: Ticket, _ waiter: Waiter) -> Bool {
        guard case .reserved = unissued[ticket.id] else {
            unissued[ticket.id] = nil
            return false
        }
        unissued[ticket.id] = .waiting(waiter)
        return true
    }

    /// Queue the request under `key`; call just before issuing it. False
    /// when it was cancelled or failed meanwhile and must not be issued.
    mutating func issue(_ ticket: Ticket, as key: Key) -> Bool {
        guard case .waiting(let waiter) = unissued[ticket.id] else { return false }
        unissued[ticket.id] = nil
        issued[key, default: []].append(Entry(id: ticket.id, waiter: waiter))
        return true
    }

    /// Withdraw the waiter and return it if it was still waiting, for the
    /// caller to resume. An issued request stays queued as abandoned.
    mutating func cancel(_ ticket: Ticket) -> Waiter? {
        switch unissued[ticket.id] {
        case .reserved:
            unissued[ticket.id] = .cancelled
            return nil
        case .waiting(let waiter):
            unissued[ticket.id] = nil
            return waiter
        case .cancelled:
            return nil
        case nil:
            break
        }
        for (key, entries) in issued {
            if let index = entries.firstIndex(where: { $0.id == ticket.id }) {
                let waiter = entries[index].waiter
                issued[key]![index].waiter = nil
                return waiter
            }
        }
        return nil
    }

    /// The callback for `key` arrived: take the oldest request for it.
    mutating func complete(_ key: Key) -> Completion {
        guard var entries = issued[key], !entries.isEmpty else { return .unexpected }
        let entry = entries.removeFirst()
        issued[key] = entries.isEmpty ? nil : entries
        if let waiter = entry.waiter { return .waiter(waiter) }
        return .abandoned(laterRequests: entries.count)
    }

    /// Bluetooth left poweredOn: no request in flight will be answered.
    /// Returns every waiter still waiting, for the caller to fail. Reserved
    /// tickets stay usable; their request is checked against the state
    /// before it is issued.
    mutating func removeAll() -> [Waiter] {
        var waiters: [Waiter] = []
        for (id, state) in unissued {
            if case .waiting(let waiter) = state {
                waiters.append(waiter)
                unissued[id] = nil
            }
        }
        for entries in issued.values {
            waiters.append(contentsOf: entries.compactMap(\.waiter))
        }
        issued = [:]
        return waiters
    }
}

extension PendingCallbacks.Completion: Equatable where Waiter: Equatable {}
