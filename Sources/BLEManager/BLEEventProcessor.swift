import Foundation
import CoreBluetooth

/// Drains the BLEEventQueue on a dedicated thread and dispatches events
/// to registered continuations and async streams. It serves one connection
/// at a time (`link`), and owns the fact of which peripheral is connected.
final class BLEEventProcessor: @unchecked Sendable {
    private let eventQueue: BLEEventQueue
    private var thread: Thread?
    private var running = false

    // Continuations for one-shot operations
    private let lock = NSLock()

    /// The connection the processor serves. Every one-shot wait and
    /// notification stream belongs to it, and events of any other peripheral
    /// are dropped.
    private enum Link {
        /// A connect was started and waits for the peripheral.
        case connecting(UUID, CheckedContinuation<Void, Error>)
        /// The peripheral connected; it is served until it disconnects.
        case connected(UUID)

        var peripheralId: UUID {
            switch self {
            case .connecting(let id, _), .connected(let id): return id
            }
        }
    }

    /// Set by beginConnect; cleared when that connect fails or is cancelled,
    /// when the peripheral disconnects, when its setup fails
    /// (endConnection) and when Bluetooth leaves poweredOn.
    private var link: Link?

    private var stateCallbacks: [(CBManagerState) -> Void] = []
    private var disconnectCallbacks: [(UUID) -> Void] = []
    private var disconnectContinuation: CheckedContinuation<Void, Error>?
    /// The GATT requests in flight and their waits, queued per answering
    /// callback in the order they were issued (see `submit`), and the writes
    /// without response waiting to be sent (see `waitToWrite`).
    private var callbacks = PendingCallbacks<CentralCallback, CentralWaiter>()
    /// The notification subscribers of each characteristic, and whether the
    /// device has notifications on (see `subscribe`). Their streams finish
    /// with the error that ended the connection.
    private var subscriptions = NotificationSubscriptions()

    // Streams for continuous data
    private var scanContinuation: AsyncStream<DiscoveredDevice>.Continuation?

    init(eventQueue: BLEEventQueue) {
        self.eventQueue = eventQueue
    }

    func start() {
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in
            self?.processLoop()
        }
        t.name = "blew.event-processor"
        t.qualityOfService = .userInitiated
        t.start()
        thread = t
    }

    func stop() {
        running = false
        eventQueue.signal()
    }

    // MARK: - Registration

    func onStateChange(_ callback: @escaping @Sendable (CBManagerState) -> Void) {
        lock.lock()
        stateCallbacks.append(callback)
        lock.unlock()
    }

    /// Called when the served connection ends (a disconnect, including one
    /// the device or the link caused), so the facade can forget it.
    func onDisconnect(_ callback: @escaping @Sendable (UUID) -> Void) {
        lock.lock()
        disconnectCallbacks.append(callback)
        lock.unlock()
    }

    func setScanContinuation(_ cont: AsyncStream<DiscoveredDevice>.Continuation?) {
        lock.lock()
        let old = scanContinuation
        scanContinuation = cont
        lock.unlock()
        // Finish the old stream so `for await` terminates
        if cont == nil {
            old?.finish()
        }
    }

    /// The peripheral that is connected, nil while none is (also while a
    /// connect is still waiting).
    var connectedPeripheralId: UUID? {
        lock.withLock {
            if case .connected(let id) = link { return id }
            return nil
        }
    }

    /// Whether a connect to `peripheral` is waiting for it.
    func isConnecting(to peripheral: UUID) -> Bool {
        lock.withLock {
            if case .connecting(let id, _) = link { return id == peripheral }
            return false
        }
    }

    /// Start serving `peripheral` and wait for it to connect: `cont` resumes
    /// on its didConnect, or fails on its didFailToConnect or didDisconnect.
    /// Events of every other peripheral are dropped from here on. The caller
    /// disconnects the current device first; a link still held is ended in
    /// blew's state only, so its device would stay connected.
    func beginConnect(to peripheral: UUID, _ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        let ended = endLink(BLEError.connectionFailed("replaced by a connect to \(peripheral.uuidString)"))
        link = .connecting(peripheral, cont)
        lock.unlock()
        for effect in ended { effect() }
    }

    /// Wait for the connected `peripheral` to disconnect. Returns true when
    /// the caller must now cancel the connection; when `peripheral` is not
    /// connected, `cont` resumes at once and this returns false.
    func beginDisconnect(from peripheral: UUID, _ cont: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        guard case .connected(peripheral) = link else {
            lock.unlock()
            cont.resume()
            return false
        }
        disconnectContinuation = cont
        lock.unlock()
        return true
    }

    // MARK: - GATT requests

    typealias Ticket = PendingCallbacks<CentralCallback, CentralWaiter>.Ticket

    /// Reserve the ticket that identifies one request, before its wait is
    /// registered, so a cancellation that comes first is not lost.
    func makeTicket() -> Ticket {
        lock.withLock { callbacks.makeTicket() }
    }

    /// Register `request`'s wait under `ticket`, then issue it on `queue`
    /// (blew.cb): queue it under the callback that answers it and run `call`,
    /// the CoreBluetooth call, in the same block. Requests for one callback
    /// are therefore queued in the order CoreBluetooth gets them, which is
    /// the order it answers them. The wait fails with `CancellationError`
    /// when the ticket was cancelled first, and with `notConnected` when
    /// `peripheral` is not the connected one when the request would go out;
    /// in both cases `call` does not run.
    func submit(_ ticket: Ticket, _ request: CentralRequest, to peripheral: UUID,
                on queue: DispatchQueue, call: @escaping @Sendable () -> Void) {
        guard lock.withLock({ callbacks.add(ticket, .request(request)) }) else {
            request.fail(CancellationError())
            return
        }
        queue.async { [self] in
            lock.lock()
            guard case .connected(peripheral) = link else {
                let waiter = callbacks.cancel(ticket)
                lock.unlock()
                waiter?.fail(BLEError.notConnected)
                return
            }
            let issued = callbacks.issue(ticket, as: request.answeredBy)
            lock.unlock()
            if issued { call() }
        }
    }

    /// Wait until the connected `peripheral` can take a write without
    /// response. `poll` runs now and again on every ready event, the waiting
    /// writes' polls in the order their tickets were made; it checks the
    /// peripheral on blew.cb and, when it can take the write, sends it
    /// through `sendIfWaiting`. Fails with `CancellationError` when the
    /// ticket was cancelled first, and `notConnected` when `peripheral` is
    /// not connected.
    func waitToWrite(_ ticket: Ticket, _ cont: CheckedContinuation<Void, Error>, to peripheral: UUID,
                     poll: @escaping @Sendable () -> Void) {
        lock.lock()
        guard callbacks.add(ticket, .readyToWrite(cont, poll: poll)) else {
            lock.unlock()
            cont.resume(throwing: CancellationError())
            return
        }
        guard case .connected(peripheral) = link else {
            _ = callbacks.cancel(ticket)
            lock.unlock()
            cont.resume(throwing: BLEError.notConnected)
            return
        }
        lock.unlock()
        poll()
    }

    /// Run `send` (the CoreBluetooth write) and resume the wait, when the
    /// write without response of `ticket` still waits; a no-op once it was
    /// sent, cancelled or failed, and for a ticket of any other request.
    /// Call on blew.cb, after finding the peripheral ready.
    func sendIfWaiting(_ ticket: Ticket, send: () -> Void) {
        let waiter = lock.withLock {
            callbacks.withdrawUnissued(ticket) {
                if case .readyToWrite = $0 { return true }
                return false
            }
        }
        guard case .readyToWrite(let cont, _)? = waiter else { return }
        send()
        cont.resume()
    }

    // MARK: - Notifications

    typealias SubscriberID = NotificationSubscriptions.ID

    /// Reserve the ID of one subscriber, before it is registered, so a
    /// cancellation that comes first is not lost.
    func makeSubscriberID() -> SubscriberID {
        lock.withLock { subscriptions.makeID() }
    }

    /// Register a subscriber of `characteristic` of the connected
    /// `peripheral`: `stream` gets every notification of it from now on, and
    /// `confirmation` resumes once the device has confirmed notifications
    /// on, which it is asked to do when this is the first subscriber.
    /// `setNotify` is the CoreBluetooth call (`setNotifyValue`); it runs on
    /// `queue` (blew.cb), and not at all once `peripheral` is no longer
    /// connected. Fails (the confirmation throws and the stream finishes)
    /// with `CancellationError` when `unsubscribe` came first, with
    /// `notConnected` when `peripheral` is not connected, with the device's
    /// error when it refuses, and with the reason when the connection ends.
    func subscribe(_ id: SubscriberID, to characteristic: String,
                   stream: AsyncThrowingStream<Data, Error>.Continuation,
                   confirmation: CheckedContinuation<Void, Error>,
                   peripheral: UUID, on queue: DispatchQueue,
                   setNotify: @escaping @Sendable (Bool) -> Void) {
        let issue: @Sendable (Bool) -> Void = { [self] enable in
            queue.async {
                guard self.lock.withLock({ if case .connected(peripheral) = self.link { return true }; return false })
                else { return }
                setNotify(enable)
            }
        }
        lock.lock()
        let effects: [() -> Void]
        if case .connected(peripheral) = link {
            effects = subscriptions.add(id, to: characteristic, stream: stream, confirmation: confirmation,
                                        setNotify: issue)
        } else {
            effects = subscriptions.refuse(id, stream: stream, confirmation: confirmation, BLEError.notConnected)
        }
        lock.unlock()
        for effect in effects { effect() }
    }

    /// The subscriber leaves: its subscribe was cancelled or its stream
    /// ended. Notifications are turned off when it was the last subscriber.
    func unsubscribe(_ id: SubscriberID) {
        let effects = lock.withLock { subscriptions.remove(id) }
        for effect in effects { effect() }
    }

    /// The number of characteristics with at least one subscriber.
    var subscribedCharacteristicCount: Int {
        lock.withLock { subscriptions.subscribedCount }
    }

    // MARK: - Cancellation

    /// End a waiting connect with CancellationError and stop serving its
    /// peripheral. A connect that already completed is left alone: its
    /// peripheral is served until it disconnects.
    func cancelConnect() {
        lock.lock()
        guard case .connecting(_, let cont) = link else { lock.unlock(); return }
        link = nil
        lock.unlock()
        cont.resume(throwing: CancellationError())
    }

    /// Stop serving the connected `peripheral` because its setup (service
    /// discovery) failed or was cancelled: its waits fail and its streams
    /// finish as on a disconnect, and its later didDisconnect is dropped. The
    /// caller cancels the CoreBluetooth connection. A no-op when `peripheral`
    /// is not the connected one.
    func endConnection(to peripheral: UUID, _ error: BLEError) {
        lock.lock()
        guard case .connected(peripheral) = link else { lock.unlock(); return }
        let ended = endLink(error)
        lock.unlock()
        for effect in ended { effect() }
    }

    func cancelDisconnectContinuation() {
        lock.lock(); let c = disconnectContinuation; disconnectContinuation = nil; lock.unlock()
        c?.resume(throwing: CancellationError())
    }

    /// Give up the request of `ticket`: its wait ends with
    /// `CancellationError`. A request already issued stays queued as
    /// abandoned, so its late answer is not taken for a later request's.
    /// One not yet issued (also a write without response still waiting) is
    /// never issued.
    func cancel(_ ticket: Ticket) {
        let waiter = lock.withLock { callbacks.cancel(ticket) }
        waiter?.fail(CancellationError())
    }

    // MARK: - Processing loop

    private func processLoop() {
        while running {
            guard let event = eventQueue.waitAndDequeue() else {
                continue
            }
            dispatch(event)
        }
    }

    /// Handle one event, then run its effects with the lock released.
    func dispatch(_ event: BLEEvent) {
        for effect in handleEvent(event) { effect() }
    }

    /// Update the registrations for one event under the lock and return its
    /// effects (yielding to or finishing streams, resuming waits, calling
    /// callbacks) for the caller to run after unlocking. Effects must not run
    /// under the lock: a stream's termination handler and a callback may call
    /// back into the processor, and NSLock is not recursive. An event of a
    /// peripheral other than the one served has no effects.
    func handleEvent(_ event: BLEEvent) -> [() -> Void] {
        lock.lock()
        defer { lock.unlock() }

        if let target = event.connectionPeripheralId, target != link?.peripheralId { return [] }

        switch event {
        case .centralStateChanged(let state):
            // The state callbacks run first, so a caller woken by the effects
            // below already sees the new state.
            var effects: [() -> Void] = stateCallbacks.map { cb in { cb(state) } }
            guard state != .poweredOn else { return effects }
            // CoreBluetooth stops scanning and drops its connections in every
            // other state; end what waits on them. Whether a per-peripheral
            // didDisconnect comes first (ending the link with connectionFailed
            // instead) is unverified; TESTS.md has the manual check.
            effects += endLink(BLEError.unavailable(state))
            if let scan = Self.take(&scanContinuation) {
                effects.append { scan.finish() }
            }
            return effects

        case .didDiscover(let id, let name, let rssi, let services, let mfgData):
            let device = DiscoveredDevice(
                identifier: id.uuidString,
                name: name,
                rssi: rssi,
                serviceUUIDs: services,
                manufacturerData: mfgData
            )
            guard let stream = scanContinuation else { return [] }
            return [{ stream.yield(device) }]

        case .didConnect(let id):
            guard case .connecting(_, let cont) = link else { return [] }
            link = .connected(id)
            return [{ cont.resume() }]

        case .didFailToConnect(_, let error):
            guard case .connecting(_, let cont) = link else { return [] }
            link = nil
            return [{ cont.resume(throwing: BLEError.connectionFailed(error ?? "unknown")) }]

        case .didDisconnect(_, let error):
            return endLink(BLEError.connectionFailed(error ?? "disconnected"))

        case .didDiscoverServices(_, let uuids, let error):
            guard case .waiter(.request(.discoverServices(let cont))) = callbacks.complete(.services) else { return [] }
            return [{ Self.settle(cont, error.map(BLEError.operationFailed), uuids) }]

        case .didDiscoverCharacteristics(_, let svcUUID, let chars, let error):
            guard case .waiter(.request(.discoverCharacteristics(_, let cont))) =
                    callbacks.complete(.characteristics(service: svcUUID)) else { return [] }
            return [{ Self.settle(cont, error.map(BLEError.operationFailed), chars) }]

        case .didDiscoverDescriptors(_, let charUUID, let descs, let error):
            guard case .waiter(.request(.discoverDescriptors(_, let cont))) =
                    callbacks.complete(.descriptors(characteristic: charUUID)) else { return [] }
            return [{ Self.settle(cont, error.map(BLEError.operationFailed), descs) }]

        case .didUpdateValue(_, let charUUID, let value, let error):
            // One callback carries both read answers and notifications, and
            // nothing tells them apart. A value with an error answers a read.
            // A value without one goes to every subscriber's stream, so no
            // notification is lost to a read; it also answers the oldest
            // read in flight, if any. While notifications are on, a read
            // therefore completes with the first value after it was issued,
            // which may be a notification, and its own answer then reaches
            // the streams.
            var effects: [() -> Void] = []
            if error == nil, let value {
                effects += subscriptions.streams(of: charUUID).map { stream in { stream.yield(value) } }
            }
            if case .waiter(.request(.read(_, let cont))) = callbacks.complete(.value(characteristic: charUUID)) {
                effects.append { Self.settle(cont, error.map(BLEError.readFailed), value ?? Data()) }
            }
            return effects

        case .didWriteValue(_, let charUUID, let error):
            guard case .waiter(.request(.write(_, let cont))) =
                    callbacks.complete(.write(characteristic: charUUID)) else { return [] }
            return [{ Self.settle(cont, error.map(BLEError.writeFailed), ()) }]

        case .isReadyToSendWriteWithoutResponse:
            // Every waiting write checks again, oldest first; each that
            // finds the peripheral ready is sent, the others keep waiting.
            // The polls queue their checks on blew.cb in this order.
            return callbacks.unissuedWaiters().compactMap {
                if case .readyToWrite(_, let poll) = $0 { return poll }
                return nil
            }

        case .didUpdateNotificationState(_, let charUUID, _, let error):
            // Answers the one setNotifyValue call in flight for the
            // characteristic, whichever way it turned them.
            return subscriptions.acknowledge(charUUID, error: error.map(BLEError.subscribeFailed))
        }
    }

    /// End the served connection, if any, with `error`: stop serving it, fail
    /// a waiting connect and every pending one-shot wait, finish the
    /// notification streams with `error`, run the disconnect callbacks and
    /// resume a waiting disconnect. The lock must be held; the returned
    /// effects run after it is released.
    private func endLink(_ error: BLEError) -> [() -> Void] {
        guard let ended = link else { return [] }
        link = nil
        let id = ended.peripheralId
        var effects: [() -> Void] = disconnectCallbacks.map { cb in { cb(id) } }
        // End the notification streams, so `for try await` loops throw why.
        effects += subscriptions.removeAll(error)

        if case .connecting(_, let cont) = ended { effects.append { cont.resume(throwing: error) } }
        effects += callbacks.removeAll().map { waiter in { waiter.fail(error) } }
        // Last, so disconnect returns with the connection forgotten and its
        // streams and waits ended.
        if let cont = Self.take(&disconnectContinuation) {
            effects.append { cont.resume() }
        }
        return effects
    }

    /// Clear a one-shot slot and return what it held.
    private static func take<T>(_ slot: inout T?) -> T? {
        defer { slot = nil }
        return slot
    }

    private static func settle<T>(_ cont: CheckedContinuation<T, Error>, _ error: BLEError?, _ value: T) {
        if let error {
            cont.resume(throwing: error)
        } else {
            cont.resume(returning: value)
        }
    }
}
