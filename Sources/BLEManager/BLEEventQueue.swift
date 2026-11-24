import Foundation

/// The FIFO that carries events from BLEDelegate (and the connect markers
/// of `BLEEventProcessor.issueConnect`), both on blew.cb, to
/// BLEEventProcessor on its own thread.
///
/// Every event is kept except scan results: a `didDiscover` that arrives
/// while `scanResultLimit` events already wait is dropped and counted in
/// `droppedScanResults`. A scan result is the only event that answers no
/// wait and that the device repeats (each advertisement is a new result),
/// so dropping one under an `allowDuplicates` flood loses at most an RSSI
/// update. Every other event answers a wait or ends one (a connect, a GATT
/// request, a disconnect, a Bluetooth state change) or is a notification
/// value that is not sent again; dropping one would hang its wait or lose
/// data silently. Their number is bounded by what the device sends while
/// the processor, which never blocks on a consumer, falls behind.
final class BLEEventQueue: @unchecked Sendable {
    /// How many waiting events stop scan results from being queued.
    let scanResultLimit: Int

    private let lock = NSLock()
    /// The waiting events from `head` on; the slots before it were taken.
    private var events: [BLEEvent] = []
    private var head = 0
    private var dropped = 0
    /// Signalled once per queued event, and by `signal()`.
    private let semaphore = DispatchSemaphore(value: 0)
    /// How many taken slots are kept before they are dropped from the array.
    private static let compactionThreshold = 1024

    init(scanResultLimit: Int = 1024) {
        precondition(scanResultLimit > 0, "scanResultLimit must be positive")
        self.scanResultLimit = scanResultLimit
    }

    /// The scan results dropped because the queue was full of waiting
    /// events.
    var droppedScanResults: Int {
        lock.withLock { dropped }
    }

    /// Queue `event`. Returns false when it was a scan result and was
    /// dropped; every other event is always queued.
    @discardableResult
    func enqueue(_ event: BLEEvent) -> Bool {
        let queued: Bool = lock.withLock {
            if case .didDiscover = event, events.count - head >= scanResultLimit {
                dropped += 1
                return false
            }
            events.append(event)
            return true
        }
        if queued { semaphore.signal() }
        return queued
    }

    /// The oldest waiting event, or nil when none waits.
    func dequeue() -> BLEEvent? {
        lock.withLock {
            guard head < events.count else { return nil }
            let event = events[head]
            head += 1
            if head == events.count {
                events.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= Self.compactionThreshold, head * 2 >= events.count {
                // Drop the taken slots once they are at least half the
                // array, so each event is moved at most once on average.
                events.removeFirst(head)
                head = 0
            }
            return event
        }
    }

    /// Block until an event is available, then dequeue it. May return nil
    /// with nothing queued: when woken by `signal()`, and for a permit left
    /// by an event an earlier call took without waiting; the caller loops.
    func waitAndDequeue() -> BLEEvent? {
        if let event = dequeue() { return event }
        semaphore.wait()
        return dequeue()
    }

    /// Wake the consumer (used for shutdown).
    func signal() {
        semaphore.signal()
    }
}
