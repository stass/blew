import Foundation
import CoreBluetooth

/// Drains the BLEEventQueue on a dedicated thread and dispatches events
/// to registered continuations and async streams.
final class BLEEventProcessor: @unchecked Sendable {
    private let eventQueue: BLEEventQueue
    private var thread: Thread?
    private var running = false

    // Continuations for one-shot operations
    private let lock = NSLock()

    private var stateCallbacks: [(CBManagerState) -> Void] = []
    private var disconnectCallbacks: [(UUID) -> Void] = []
    private var connectContinuation: CheckedContinuation<Void, Error>?
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
    private var notificationContinuations: [String: AsyncStream<Data>.Continuation] = [:]

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

    /// Called for every disconnect, including one the device or the link
    /// caused, so the facade can forget the connection.
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

    func setConnectContinuation(_ cont: CheckedContinuation<Void, Error>?) {
        lock.lock()
        connectContinuation = cont
        lock.unlock()
    }

    func setDisconnectContinuation(_ cont: CheckedContinuation<Void, Error>?) {
        lock.lock()
        disconnectContinuation = cont
        lock.unlock()
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

    func setNotificationContinuation(forChar uuid: String, _ cont: AsyncStream<Data>.Continuation?) {
        lock.lock()
        notificationContinuations[uuid] = cont
        lock.unlock()
    }

    // MARK: - Cancellation

    func cancelConnectContinuation() {
        lock.lock(); let c = connectContinuation; connectContinuation = nil; lock.unlock()
        c?.resume(throwing: CancellationError())
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
    /// back into the processor, and NSLock is not recursive.
    func handleEvent(_ event: BLEEvent) -> [() -> Void] {
        lock.lock()
        defer { lock.unlock() }

        switch event {
        case .centralStateChanged(let state):
            return stateCallbacks.map { cb in { cb(state) } }

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

        case .didConnect:
            guard let cont = Self.take(&connectContinuation) else { return [] }
            return [{ cont.resume() }]

        case .didFailToConnect(_, let error):
            guard let cont = Self.take(&connectContinuation) else { return [] }
            return [{ cont.resume(throwing: BLEError.connectionFailed(error ?? "unknown")) }]

        case .didDisconnect(let peripheralId, let error):
            var effects: [() -> Void] = disconnectCallbacks.map { cb in { cb(peripheralId) } }
            if let cont = Self.take(&disconnectContinuation) {
                effects.append { cont.resume() }
            }
            // End the notification streams, so `for await` loops finish.
            effects += notificationContinuations.values.map { stream in { stream.finish() } }
            notificationContinuations.removeAll()

            // Fail every pending one-shot wait.
            let connError = BLEError.connectionFailed(error ?? "disconnected")
            func fail<T>(_ cont: CheckedContinuation<T, Error>?) {
                if let cont { effects.append { cont.resume(throwing: connError) } }
            }
            fail(Self.take(&connectContinuation))
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
            return effects

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
