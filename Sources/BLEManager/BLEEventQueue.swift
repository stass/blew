import Foundation
import Atomics

/// Lock-free SPSC (single-producer, single-consumer) ring buffer for BLE events.
///
/// Producer: BLEDelegate on CoreBluetooth's dispatch queue.
/// Consumer: BLEEventProcessor on a dedicated thread.
///
/// If the queue is full, the newest event is dropped and `droppedCount` is incremented.
final class BLEEventQueue: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<BLEEvent?>
    private let head = ManagedAtomic<Int>(0) // write position (producer)
    private let tail = ManagedAtomic<Int>(0) // read position (consumer)
    private let _droppedCount = ManagedAtomic<Int>(0)
    private let semaphore = DispatchSemaphore(value: 0)

    var droppedCount: Int {
        _droppedCount.load(ordering: .relaxed)
    }

    init(capacity: Int = 1024) {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0, "Capacity must be a power of 2")
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
        self.buffer.initialize(repeating: nil, count: capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Enqueue an event. Called by the producer (BLEDelegate).
    /// Returns false if the queue was full (event dropped).
    @discardableResult
    func enqueue(_ event: BLEEvent) -> Bool {
        let currentHead = head.load(ordering: .relaxed)
        let currentTail = tail.load(ordering: .acquiring)
        let nextHead = (currentHead + 1) & (capacity - 1)

        if nextHead == currentTail {
            _droppedCount.wrappingIncrement(ordering: .relaxed)
            return false
        }

        buffer[currentHead] = event
        head.store(nextHead, ordering: .releasing)
        semaphore.signal()
        return true
    }

    /// Dequeue an event. Called by the consumer (BLEEventProcessor).
    /// Returns nil if the queue is empty.
    func dequeue() -> BLEEvent? {
        let currentTail = tail.load(ordering: .relaxed)
        let currentHead = head.load(ordering: .acquiring)

        if currentTail == currentHead {
            return nil
        }

        let event = buffer[currentTail]
        buffer[currentTail] = nil
        tail.store((currentTail + 1) & (capacity - 1), ordering: .releasing)
        return event
    }

    /// Block until an event is available, then dequeue it.
    func waitAndDequeue() -> BLEEvent? {
        while true {
            if let event = dequeue() {
                return event
            }
            semaphore.wait()
        }
    }

    /// Signal the consumer to wake up (used for shutdown).
    func signal() {
        semaphore.signal()
    }
}
