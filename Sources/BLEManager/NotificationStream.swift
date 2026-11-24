import Foundation

/// One subscriber's notification values, as `BLECentral.subscribe` returns
/// them. Notifications have no flow control: the device sends them as fast
/// as it likes, whether or not the subscriber reads. So at most `capacity`
/// values wait for the reader; when another comes while that many wait, the
/// oldest waiting one is dropped and counted in `droppedCount`. Each
/// subscriber has its own buffer and count, so a slow one loses values
/// without slowing down or costing the others any. The stream throws the
/// reason when the subscription ends with an error (the connection ended).
public struct NotificationStream: AsyncSequence, Sendable {
    public typealias Element = Data

    /// The most values waiting for one reader: about a second of a fast
    /// device's notifications, and at most 512 KiB, since an attribute value
    /// is at most 512 bytes (Core Specification Vol 3, Part F, 3.2.9).
    public static let capacity = 1024

    /// Each value with its place in the order the device sent them, so a
    /// reader can tell where values were dropped.
    private let values: AsyncThrowingStream<NumberedValue, Error>
    /// Where the processor delivers this subscriber's values.
    let sink: NotificationSink

    /// The values dropped so far because `capacity` were waiting.
    public var droppedCount: Int { sink.droppedCount }

    /// A stream and its sink; `onTermination` runs once when the stream
    /// ends, however it ends (finished, or its reader stopped).
    init(onTermination: @escaping @Sendable () -> Void) {
        let (values, continuation) = AsyncThrowingStream<NumberedValue, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.capacity))
        continuation.onTermination = { _ in onTermination() }
        self.values = values
        self.sink = NotificationSink(continuation)
    }

    /// The values alone, for a reader to whom a gap does not matter.
    public func makeAsyncIterator() -> Iterator {
        Iterator(gaps: GapIterator(numbered: values.makeAsyncIterator()))
    }

    /// The values, each with the number dropped right before it: for a
    /// reader that must not join the values on either side of a drop. Read
    /// the stream either this way or as plain values, from the start: the
    /// counts are of the values this reader did not get.
    public var withGaps: WithGaps { WithGaps(values: values) }

    /// A received value and the values dropped between it and the one the
    /// reader received before it (or the start of the subscription).
    public struct Received: Sendable, Equatable {
        public let data: Data
        public let droppedBefore: Int
    }

    public struct Iterator: AsyncIteratorProtocol {
        fileprivate var gaps: GapIterator

        public mutating func next() async throws -> Data? {
            try await gaps.next()?.data
        }
    }

    public struct WithGaps: AsyncSequence, Sendable {
        public typealias Element = Received
        fileprivate let values: AsyncThrowingStream<NumberedValue, Error>

        public func makeAsyncIterator() -> GapIterator {
            GapIterator(numbered: values.makeAsyncIterator())
        }
    }

    /// Turns the numbers of the values received into the counts dropped
    /// between them.
    public struct GapIterator: AsyncIteratorProtocol {
        fileprivate var numbered: AsyncThrowingStream<NumberedValue, Error>.AsyncIterator
        /// The number of the value expected next if none is dropped.
        private var expected = 0

        fileprivate init(numbered: AsyncThrowingStream<NumberedValue, Error>.AsyncIterator) {
            self.numbered = numbered
        }

        public mutating func next() async throws -> Received? {
            guard let value = try await numbered.next() else { return nil }
            defer { expected = value.number + 1 }
            return Received(data: value.data, droppedBefore: value.number - expected)
        }
    }
}

/// A value and its place among the values yielded to one stream, counting
/// from 0.
struct NumberedValue: Sendable {
    let number: Int
    let data: Data
}

/// The producer end of a `NotificationStream`: the processor yields each
/// notification to it and finishes it when the subscription ends. Counts
/// the values the bounded buffer drops.
final class NotificationSink: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<NumberedValue, Error>.Continuation
    private let lock = NSLock()
    private var dropped = 0
    /// The number the next value yielded gets.
    private var next = 0

    fileprivate init(_ continuation: AsyncThrowingStream<NumberedValue, Error>.Continuation) {
        self.continuation = continuation
    }

    var droppedCount: Int { lock.withLock { dropped } }

    /// Numbers and yields under one lock, so the numbers follow the order
    /// of the buffer whichever thread yields.
    func yield(_ value: Data) {
        lock.withLock {
            if case .dropped = continuation.yield(NumberedValue(number: next, data: value)) {
                dropped += 1
            }
            next += 1
        }
    }

    func finish(throwing error: Error? = nil) {
        continuation.finish(throwing: error)
    }
}
