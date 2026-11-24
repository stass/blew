import Foundation
import CoreBluetooth

/// One connect of the central to one peripheral, made by
/// `makeConnectAttempt(to:)`. Two attempts to the same device are
/// different attempts, so a cancel or a deadline of one cannot end another.
public struct ConnectAttempt: Hashable, Sendable {
    public let peripheral: UUID
    fileprivate let serial: UInt64
}

/// One wait for the connected peripheral to disconnect, made by
/// `makeDisconnectWait()`.
struct DisconnectWait: Hashable, Sendable {
    fileprivate let serial: UInt64
}

/// Drains the BLEEventQueue on a dedicated thread and dispatches events
/// to registered continuations and async streams. It serves one connection
/// at a time (`link`), and owns the facts of which peripheral is connected
/// and of the central's Bluetooth state.
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
        /// A connect was registered and waits for the peripheral. `issued`
        /// turns true when the processor dequeues the attempt's
        /// `connectIssued` marker, which BLECentral queues on blew.cb just
        /// before the CoreBluetooth connect call. Only then does the
        /// peripheral's didConnect or didFailToConnect answer the attempt:
        /// one queued before the marker belongs to an earlier attempt.
        case connecting(ConnectAttempt, CheckedContinuation<Void, Error>, issued: Bool)
        /// The peripheral connected; it is served until it disconnects.
        case connected(ConnectAttempt)

        var attempt: ConnectAttempt {
            switch self {
            case .connecting(let attempt, _, _), .connected(let attempt): return attempt
            }
        }

        var peripheralId: UUID { attempt.peripheral }
    }

    /// Set by beginConnect; cleared when that connect fails, is cancelled or
    /// passes its deadline, when the peripheral disconnects, when its setup
    /// fails (endConnection) and when Bluetooth leaves poweredOn.
    private var link: Link?

    /// The central's state from its last `centralStateChanged`. Nothing is
    /// registered while it is not poweredOn: CoreBluetooth would answer
    /// nothing, so the wait would never end.
    private var state: CBManagerState = .unknown

    /// Numbers the connect attempts and disconnect waits.
    private var lastSerial: UInt64 = 0

    private var linkEndedCallbacks: [(ConnectAttempt) -> Void] = []
    /// Where and how a connection blew gave up is cancelled in CoreBluetooth
    /// (see `onCancelConnection`).
    private var connectionCanceller: (queue: DispatchQueue, cancel: @Sendable (UUID) -> Void)?
    private var disconnectWaits: [DisconnectWait: CheckedContinuation<Void, Error>] = [:]
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

    /// The central's Bluetooth state, as CoreBluetooth last reported it.
    var centralState: CBManagerState {
        lock.withLock { state }
    }

    /// Called with the attempt when the served link ends, however it ended,
    /// so the facade can forget that connection.
    func onLinkEnded(_ callback: @escaping @Sendable (ConnectAttempt) -> Void) {
        lock.lock()
        linkEndedCallbacks.append(callback)
        lock.unlock()
    }

    /// How a connection blew gave up (a cancelled or replaced connect, a
    /// connect past its deadline, a failed setup) is cancelled: `cancel`
    /// (`cancelPeripheralConnection`) runs on `queue` (blew.cb) for its
    /// peripheral, because CoreBluetooth may still hold or be making that
    /// connection. It is queued while the processor still holds the lock
    /// that ended the link, so it runs before the connect call of any later
    /// attempt (whose `issueConnect` is queued after that attempt's
    /// `beginConnect` took the lock) and after the ended attempt's own. A
    /// link CoreBluetooth ended (didDisconnect, didFailToConnect, Bluetooth
    /// leaving poweredOn) is not cancelled.
    func onCancelConnection(on queue: DispatchQueue, _ cancel: @escaping @Sendable (UUID) -> Void) {
        lock.withLock { connectionCanceller = (queue, cancel) }
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
            if case .connected(let attempt) = link { return attempt.peripheral }
            return nil
        }
    }

    /// Whether `attempt` waits for its peripheral to connect.
    func isConnecting(_ attempt: ConnectAttempt) -> Bool {
        lock.withLock {
            if case .connecting(attempt, _, _) = link { return true }
            return false
        }
    }

    /// Whether `attempt` connected and is still served.
    func isConnected(_ attempt: ConnectAttempt) -> Bool {
        lock.withLock {
            if case .connected(attempt) = link { return true }
            return false
        }
    }

    /// Reserve the identity of one connect to `peripheral`, before its wait
    /// is registered, so its cancellation handler and deadline name it.
    func makeConnectAttempt(to peripheral: UUID) -> ConnectAttempt {
        lock.withLock {
            lastSerial += 1
            return ConnectAttempt(peripheral: peripheral, serial: lastSerial)
        }
    }

    /// Start serving `attempt`'s peripheral and wait for it to connect:
    /// `cont` resumes on its didConnect, or fails on its didFailToConnect
    /// (both only after the attempt's `connectIssued` marker), and fails
    /// with `BLEError.timeout` when it has not connected `timeout` seconds
    /// from now (checked on `queue`, blew.cb). Events of every other
    /// peripheral are dropped from here on. A link still held is ended, and
    /// its peripheral handed to the link-ended callbacks to cancel. Fails at
    /// once with `bluetoothUnavailable` while Bluetooth is not poweredOn.
    func beginConnect(_ attempt: ConnectAttempt, timeout: TimeInterval, on queue: DispatchQueue,
                      _ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard state == .poweredOn else {
            let error = BLEError.unavailable(state)
            lock.unlock()
            cont.resume(throwing: error)
            return
        }
        let replaced = endLink(BLEError.connectionFailed("replaced by a connect to \(attempt.peripheral.uuidString)"),
                               mustCancel: true)
        link = .connecting(attempt, cont, issued: false)
        lock.unlock()
        for effect in replaced { effect() }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.cancelConnect(attempt, BLEError.timeout)
        }
    }

    /// Reserve the identity of one disconnect wait, before it is registered,
    /// so its cancellation handler names it.
    func makeDisconnectWait() -> DisconnectWait {
        lock.withLock {
            lastSerial += 1
            return DisconnectWait(serial: lastSerial)
        }
    }

    /// Wait for the connected `peripheral` to disconnect. Returns true when
    /// the caller must now cancel the connection; when `peripheral` is not
    /// connected (also while Bluetooth is not poweredOn, which ended every
    /// link), `cont` resumes at once and this returns false. Each wait
    /// resumes when the link ends; several may wait at once.
    func beginDisconnect(_ wait: DisconnectWait, from peripheral: UUID,
                         _ cont: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        guard case .connected(let attempt) = link, attempt.peripheral == peripheral else {
            lock.unlock()
            cont.resume()
            return false
        }
        disconnectWaits[wait] = cont
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
    /// when the ticket was cancelled first, and when the request would go
    /// out with `bluetoothUnavailable` while Bluetooth is not poweredOn and
    /// `notConnected` when `peripheral` is not the connected one; in each
    /// case `call` does not run.
    func submit(_ ticket: Ticket, _ request: CentralRequest, to peripheral: UUID,
                on queue: DispatchQueue, call: @escaping @Sendable () -> Void) {
        guard lock.withLock({ callbacks.add(ticket, .request(request)) }) else {
            request.fail(CancellationError())
            return
        }
        queue.async { [self] in
            lock.lock()
            if let refusal = refusal(to: peripheral) {
                let waiter = callbacks.cancel(ticket)
                lock.unlock()
                waiter?.fail(refusal)
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
    /// ticket was cancelled first, `bluetoothUnavailable` while Bluetooth is
    /// not poweredOn, and `notConnected` when `peripheral` is not connected.
    func waitToWrite(_ ticket: Ticket, _ cont: CheckedContinuation<Void, Error>, to peripheral: UUID,
                     poll: @escaping @Sendable () -> Void) {
        lock.lock()
        guard callbacks.add(ticket, .readyToWrite(cont, poll: poll)) else {
            lock.unlock()
            cont.resume(throwing: CancellationError())
            return
        }
        if let refusal = refusal(to: peripheral) {
            _ = callbacks.cancel(ticket)
            lock.unlock()
            cont.resume(throwing: refusal)
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
    /// `bluetoothUnavailable` while Bluetooth is not poweredOn, with
    /// `notConnected` when `peripheral` is not connected, with the device's
    /// error when it refuses, and with the reason when the connection ends.
    func subscribe(_ id: SubscriberID, to characteristic: String,
                   stream: AsyncThrowingStream<Data, Error>.Continuation,
                   confirmation: CheckedContinuation<Void, Error>,
                   peripheral: UUID, on queue: DispatchQueue,
                   setNotify: @escaping @Sendable (Bool) -> Void) {
        let issue: @Sendable (Bool) -> Void = { [self] enable in
            queue.async {
                guard self.lock.withLock({ self.refusal(to: peripheral) == nil }) else { return }
                setNotify(enable)
            }
        }
        lock.lock()
        let effects: [() -> Void]
        if let refusal = refusal(to: peripheral) {
            effects = subscriptions.refuse(id, stream: stream, confirmation: confirmation, refusal)
        } else {
            effects = subscriptions.add(id, to: characteristic, stream: stream, confirmation: confirmation,
                                        setNotify: issue)
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

    // MARK: - Connect call and cancellation

    /// Run `connect`, the CoreBluetooth connect call of `attempt`, unless
    /// the attempt no longer waits. Call on blew.cb: the attempt's
    /// `connectIssued` marker is queued in the same block, behind every
    /// event CoreBluetooth queued before the call, so the attempt takes only
    /// a didConnect or didFailToConnect that came after it.
    func issueConnect(_ attempt: ConnectAttempt, connect: () -> Void) {
        guard isConnecting(attempt) else { return }
        eventQueue.enqueue(.connectIssued(attempt))
        connect()
    }

    /// End `attempt` while it waits for its peripheral: the wait fails with
    /// `error` (CancellationError for a cancel, `BLEError.timeout` at its
    /// deadline) and the CoreBluetooth connect is cancelled
    /// (`onCancelConnection`). A no-op once the attempt connected, failed or was replaced:
    /// a connected peripheral is served until it disconnects.
    func cancelConnect(_ attempt: ConnectAttempt, _ error: Error = CancellationError()) {
        let ended: [() -> Void] = lock.withLock {
            guard case .connecting(attempt, _, _) = link else { return [] }
            return endLink(error, mustCancel: true)
        }
        for effect in ended { effect() }
    }

    /// Stop serving `attempt`'s connection because its setup (service
    /// discovery) failed or was cancelled: its waits fail and its streams
    /// finish as on a disconnect, and its later didDisconnect is dropped. The
    /// CoreBluetooth connection is cancelled (`onCancelConnection`). A no-op when
    /// `attempt` is not the connected one.
    func endConnection(_ attempt: ConnectAttempt, _ error: BLEError) {
        let ended: [() -> Void] = lock.withLock {
            guard case .connected(attempt) = link else { return [] }
            return endLink(error, mustCancel: true)
        }
        for effect in ended { effect() }
    }

    /// Give up the disconnect wait `wait`: it ends with CancellationError.
    /// A no-op once it resumed.
    func cancelDisconnect(_ wait: DisconnectWait) {
        let cont = lock.withLock { disconnectWaits.removeValue(forKey: wait) }
        cont?.resume(throwing: CancellationError())
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
        case .centralStateChanged(let newState):
            // Set under the lock that registrations take, so a registration
            // either sees the new state and is refused, or came first and is
            // ended below; a caller woken by these effects sees it too.
            state = newState
            guard newState != .poweredOn else { return [] }
            // CoreBluetooth stops scanning and drops its connections in every
            // other state; end what waits on them. Whether a per-peripheral
            // didDisconnect comes first (ending the link with connectionFailed
            // instead) is unverified; TESTS.md has the manual check.
            var effects = endLink(BLEError.unavailable(newState), mustCancel: false)
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

        case .connectIssued(let attempt):
            guard case .connecting(attempt, let cont, issued: false) = link else { return [] }
            link = .connecting(attempt, cont, issued: true)
            return []

        case .didConnect:
            guard case .connecting(let attempt, let cont, issued: true) = link else { return [] }
            link = .connected(attempt)
            return [{ cont.resume() }]

        case .didFailToConnect(_, let error):
            guard case .connecting(_, _, issued: true) = link else { return [] }
            return endLink(BLEError.connectionFailed(error ?? "unknown"), mustCancel: false)

        case .didDisconnect(_, let error):
            // CoreBluetooth answers a connect with didConnect or
            // didFailToConnect; a didDisconnect while connecting is the late
            // answer to blew cancelling an earlier connection to the device
            // (a failed setup, a cancelled connect), not this attempt's.
            guard case .connected = link else { return [] }
            return endLink(BLEError.connectionFailed(error ?? "disconnected"), mustCancel: false)

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
    /// notification streams with `error`, run the link-ended callbacks and
    /// resume the waiting disconnects. When blew, not CoreBluetooth, ended it
    /// (`mustCancel`), queue the cancel of its connection now, under the
    /// lock (see `onCancelConnection`). The lock must be held; the returned
    /// effects run after it is released.
    private func endLink(_ error: Error, mustCancel: Bool) -> [() -> Void] {
        guard let ended = link else { return [] }
        link = nil
        let id = ended.peripheralId
        if mustCancel, let canceller = connectionCanceller {
            canceller.queue.async { canceller.cancel(id) }
        }
        var effects: [() -> Void] = linkEndedCallbacks.map { cb in { cb(ended.attempt) } }
        // End the notification streams, so `for try await` loops throw why.
        effects += subscriptions.removeAll(error)

        if case .connecting(_, let cont, _) = ended { effects.append { cont.resume(throwing: error) } }
        effects += callbacks.removeAll().map { waiter in { waiter.fail(error) } }
        // Last, so disconnect returns with the connection forgotten and its
        // streams and waits ended.
        let waits = disconnectWaits.values
        disconnectWaits = [:]
        effects += waits.map { cont in { cont.resume() } }
        return effects
    }

    /// Why a request to `peripheral` cannot go out now, nil when it can:
    /// Bluetooth is not poweredOn, or `peripheral` is not the connected one.
    /// The lock must be held.
    private func refusal(to peripheral: UUID) -> BLEError? {
        guard state == .poweredOn else { return .unavailable(state) }
        guard case .connected(let attempt) = link, attempt.peripheral == peripheral else { return .notConnected }
        return nil
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
