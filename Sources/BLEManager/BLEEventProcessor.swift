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
    private var discoverServicesContinuation: CheckedContinuation<[String], Error>?
    private var discoverCharsContinuations: [String: CheckedContinuation<[BLEEvent.DiscoveredCharacteristic], Error>] = [:]
    private var discoverDescContinuations: [String: CheckedContinuation<[String], Error>] = [:]
    private var readContinuations: [String: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var subscribeContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var writeReadyContinuation: CheckedContinuation<Void, Error>?

    // Streams for continuous data
    private var scanContinuation: AsyncStream<DiscoveredDevice>.Continuation?
    /// Finished with the error that ended the connection.
    private var notificationContinuations: [String: AsyncThrowingStream<Data, Error>.Continuation] = [:]

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

    func setDiscoverServicesContinuation(_ cont: CheckedContinuation<[String], Error>?) {
        lock.lock()
        discoverServicesContinuation = cont
        lock.unlock()
    }

    func setDiscoverCharsContinuation(forService uuid: String, _ cont: CheckedContinuation<[BLEEvent.DiscoveredCharacteristic], Error>?) {
        lock.lock()
        discoverCharsContinuations[uuid] = cont
        lock.unlock()
    }

    func setDiscoverDescContinuation(forChar uuid: String, _ cont: CheckedContinuation<[String], Error>?) {
        lock.lock()
        discoverDescContinuations[uuid] = cont
        lock.unlock()
    }

    func setReadContinuation(forChar uuid: String, _ cont: CheckedContinuation<Data, Error>?) {
        lock.lock()
        readContinuations[uuid] = cont
        lock.unlock()
    }

    func setWriteContinuation(forChar uuid: String, _ cont: CheckedContinuation<Void, Error>?) {
        lock.lock()
        writeContinuations[uuid] = cont
        lock.unlock()
    }

    func setSubscribeContinuation(forChar uuid: String, _ cont: CheckedContinuation<Void, Error>?) {
        lock.lock()
        subscribeContinuations[uuid] = cont
        lock.unlock()
    }

    func setWriteReadyContinuation(_ cont: CheckedContinuation<Void, Error>?) {
        lock.lock()
        writeReadyContinuation = cont
        lock.unlock()
    }

    /// Resume a pending write-ready wait because the peripheral was found ready
    /// when polled; a no-op when the ready event already resumed it.
    func resumeWriteReady() {
        lock.lock(); let c = writeReadyContinuation; writeReadyContinuation = nil; lock.unlock()
        c?.resume()
    }

    func setNotificationContinuation(forChar uuid: String, _ cont: AsyncThrowingStream<Data, Error>.Continuation?) {
        lock.lock()
        notificationContinuations[uuid] = cont
        lock.unlock()
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

    func cancelDiscoverServicesContinuation() {
        lock.lock(); let c = discoverServicesContinuation; discoverServicesContinuation = nil; lock.unlock()
        c?.resume(throwing: CancellationError())
    }

    func cancelDiscoverCharsContinuation(forService uuid: String) {
        lock.lock(); let c = discoverCharsContinuations.removeValue(forKey: uuid); lock.unlock()
        c?.resume(throwing: CancellationError())
    }

    func cancelDiscoverDescContinuation(forChar uuid: String) {
        lock.lock(); let c = discoverDescContinuations.removeValue(forKey: uuid); lock.unlock()
        c?.resume(throwing: CancellationError())
    }

    func cancelReadContinuation(forChar uuid: String) {
        lock.lock(); let c = readContinuations.removeValue(forKey: uuid); lock.unlock()
        c?.resume(throwing: CancellationError())
    }

    func cancelWriteContinuation(forChar uuid: String) {
        lock.lock(); let c = writeContinuations.removeValue(forKey: uuid); lock.unlock()
        c?.resume(throwing: CancellationError())
    }

    func cancelWriteReadyContinuation() {
        lock.lock(); let c = writeReadyContinuation; writeReadyContinuation = nil; lock.unlock()
        c?.resume(throwing: CancellationError())
    }

    func cancelSubscribeContinuation(forChar uuid: String) {
        lock.lock(); let c = subscribeContinuations.removeValue(forKey: uuid); lock.unlock()
        c?.resume(throwing: CancellationError())
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
            guard let cont = Self.take(&discoverServicesContinuation) else { return [] }
            return [{ Self.settle(cont, error.map(BLEError.operationFailed), uuids) }]

        case .didDiscoverCharacteristics(_, let svcUUID, let chars, let error):
            guard let cont = discoverCharsContinuations.removeValue(forKey: svcUUID) else { return [] }
            return [{ Self.settle(cont, error.map(BLEError.operationFailed), chars) }]

        case .didDiscoverDescriptors(_, let charUUID, let descs, let error):
            guard let cont = discoverDescContinuations.removeValue(forKey: charUUID) else { return [] }
            return [{ Self.settle(cont, error.map(BLEError.operationFailed), descs) }]

        case .didUpdateValue(_, let charUUID, let value, let error):
            // A one-shot read takes the value; otherwise a notification stream does.
            if let cont = readContinuations.removeValue(forKey: charUUID) {
                return [{ Self.settle(cont, error.map(BLEError.readFailed), value ?? Data()) }]
            }
            guard let stream = notificationContinuations[charUUID], let value else { return [] }
            return [{ stream.yield(value) }]

        case .didWriteValue(_, let charUUID, let error):
            guard let cont = writeContinuations.removeValue(forKey: charUUID) else { return [] }
            return [{ Self.settle(cont, error.map(BLEError.writeFailed), ()) }]

        case .isReadyToSendWriteWithoutResponse:
            guard let cont = Self.take(&writeReadyContinuation) else { return [] }
            return [{ cont.resume() }]

        case .didUpdateNotificationState(_, let charUUID, _, let error):
            guard let cont = subscribeContinuations.removeValue(forKey: charUUID) else { return [] }
            return [{ Self.settle(cont, error.map(BLEError.subscribeFailed), ()) }]
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
        effects += notificationContinuations.values.map { stream in { stream.finish(throwing: error) } }
        notificationContinuations.removeAll()

        func fail<T>(_ cont: CheckedContinuation<T, Error>?) {
            if let cont { effects.append { cont.resume(throwing: error) } }
        }
        if case .connecting(_, let cont) = ended { fail(cont) }
        fail(Self.take(&discoverServicesContinuation))
        fail(Self.take(&writeReadyContinuation))
        for cont in discoverCharsContinuations.values { fail(cont) }
        for cont in discoverDescContinuations.values { fail(cont) }
        for cont in readContinuations.values { fail(cont) }
        for cont in writeContinuations.values { fail(cont) }
        for cont in subscribeContinuations.values { fail(cont) }
        discoverCharsContinuations.removeAll()
        discoverDescContinuations.removeAll()
        readContinuations.removeAll()
        writeContinuations.removeAll()
        subscribeContinuations.removeAll()
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
