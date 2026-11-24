import Foundation

/// One scan's discoveries, as `BLECentral.scan` returns them. Advertisements
/// have no flow control, and a scan that allows duplicates gets one for
/// every advertisement of every device in range, so the stream keeps at most
/// one result per device waiting for the reader: an advertisement of a device
/// whose result is still unread merges into it (`DiscoveredDevice.merging`)
/// and keeps its place. Waiting results are read in the order their devices
/// were first seen while unread, each device's first sighting is delivered,
/// and what waits is bounded by the number of distinct devices the scan sees.
/// When the scan ends, the waiting results are read first; then the stream
/// finishes, or throws the reason the scan ended with an error.
public struct ScanStream: AsyncSequence, Sendable {
    public typealias Element = DiscoveredDevice

    /// Tells the reader that results wait. At most one wake-up waits, so it
    /// holds no results; its termination is the scan's end.
    private let wakeupStream: AsyncThrowingStream<Void, Error>
    /// Where the processor delivers this scan's discoveries.
    let sink: ScanSink

    /// A stream and its sink; `onTermination` runs once when the stream
    /// ends, however it ends (finished, or its reader stopped).
    init(onTermination: @escaping @Sendable () -> Void) {
        let (wakeupStream, continuation) = AsyncThrowingStream<Void, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { _ in onTermination() }
        self.wakeupStream = wakeupStream
        self.sink = ScanSink(continuation)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(wakeupReader: wakeupStream.makeAsyncIterator(), sink: sink)
    }

    public struct Iterator: AsyncIteratorProtocol {
        fileprivate var wakeupReader: AsyncThrowingStream<Void, Error>.AsyncIterator
        fileprivate let sink: ScanSink
        /// How the scan ended, once the wake-ups ended; what waits is read
        /// before it is reported.
        private var end: End?

        private enum End {
            case finished
            case failed(Error)
        }

        fileprivate init(wakeupReader: AsyncThrowingStream<Void, Error>.AsyncIterator, sink: ScanSink) {
            self.wakeupReader = wakeupReader
            self.sink = sink
        }

        /// The next waiting result. A cancelled reader gets nil at once and
        /// ends the scan, also while results keep arriving faster than it
        /// reads them.
        public mutating func next() async throws -> DiscoveredDevice? {
            while true {
                if Task.isCancelled {
                    sink.finish()
                    return nil
                }
                if let device = sink.take() { return device }
                switch end {
                case .finished:
                    return nil
                case .failed(let error):
                    end = .finished
                    throw error
                case nil:
                    break
                }
                do {
                    if try await wakeupReader.next() == nil { end = .finished }
                } catch {
                    end = .failed(error)
                }
            }
        }
    }
}

/// The producer end of a `ScanStream`: the processor delivers each discovery
/// to it and finishes it when the scan ends. Holds the results waiting for
/// the reader, one per device.
final class ScanSink: @unchecked Sendable {
    private let wakeupSender: AsyncThrowingStream<Void, Error>.Continuation
    private let lock = NSLock()
    /// The waiting results' identifiers in the order their devices were
    /// first seen while unread; `order[head...]` wait.
    private var order: [String] = []
    private var head = 0
    private var waiting: [String: DiscoveredDevice] = [:]
    /// Set once the scan ended; a discovery delivered after it is dropped.
    private var finished = false

    fileprivate init(_ wakeupSender: AsyncThrowingStream<Void, Error>.Continuation) {
        self.wakeupSender = wakeupSender
    }

    func yield(_ device: DiscoveredDevice) {
        let accepted: Bool = lock.withLock {
            guard !finished else { return false }
            if let earlier = waiting[device.identifier] {
                waiting[device.identifier] = earlier.merging(device)
            } else {
                waiting[device.identifier] = device
                order.append(device.identifier)
            }
            return true
        }
        if accepted { wakeupSender.yield(()) }
    }

    func finish(throwing error: Error? = nil) {
        lock.withLock { finished = true }
        wakeupSender.finish(throwing: error)
    }

    /// The first waiting result, nil when none waits.
    fileprivate func take() -> DiscoveredDevice? {
        lock.withLock {
            guard head < order.count else { return nil }
            let identifier = order[head]
            head += 1
            // Drop the read prefix once it is half the array, so a reader
            // that never catches up does not keep the identifiers it read.
            if head * 2 >= order.count {
                order.removeFirst(head)
                head = 0
            }
            // Each waiting identifier is in `order` once, after `head`.
            guard let device = waiting.removeValue(forKey: identifier) else {
                preconditionFailure("a waiting scan result is missing")
            }
            return device
        }
    }
}
