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

    private let values: AsyncThrowingStream<Data, Error>
    /// Where the processor delivers this subscriber's values.
    let sink: NotificationSink

    /// The values dropped so far because `capacity` were waiting.
    public var droppedCount: Int { sink.droppedCount }

    /// A stream and its sink; `onTermination` runs once when the stream
    /// ends, however it ends (finished, or its reader stopped).
    init(onTermination: @escaping @Sendable () -> Void) {
        let (values, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.capacity))
        continuation.onTermination = { _ in onTermination() }
        self.values = values
        self.sink = NotificationSink(continuation)
    }

    public func makeAsyncIterator() -> AsyncThrowingStream<Data, Error>.AsyncIterator {
        values.makeAsyncIterator()
    }
}

/// The producer end of a `NotificationStream`: the processor yields each
/// notification to it and finishes it when the subscription ends. Counts
/// the values the bounded buffer drops.
final class NotificationSink: @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var dropped = 0

    fileprivate init(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    var droppedCount: Int { lock.withLock { dropped } }

    func yield(_ value: Data) {
        if case .dropped = continuation.yield(value) {
            lock.withLock { dropped += 1 }
        }
    }

    func finish(throwing error: Error? = nil) {
        continuation.finish(throwing: error)
    }
}
