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
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var disconnectContinuation: CheckedContinuation<Void, Error>?
    private var discoverServicesContinuation: CheckedContinuation<[String], Error>?
    private var discoverCharsContinuations: [String: CheckedContinuation<[BLEEvent.DiscoveredCharacteristic], Error>] = [:]
    private var discoverDescContinuations: [String: CheckedContinuation<[String], Error>] = [:]
    private var readContinuations: [String: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var subscribeContinuations: [String: CheckedContinuation<Void, Error>] = [:]

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

    func setNotificationContinuation(forChar uuid: String, _ cont: AsyncStream<Data>.Continuation?) {
        lock.lock()
        notificationContinuations[uuid] = cont
        lock.unlock()
    }

    // MARK: - Processing loop

    private func processLoop() {
        while running {
            guard let event = eventQueue.waitAndDequeue() else {
                continue
            }
            handleEvent(event)
        }
    }

    private func handleEvent(_ event: BLEEvent) {
        lock.lock()
        defer { lock.unlock() }

        switch event {
        case .centralStateChanged(let state):
            for cb in stateCallbacks { cb(state) }

        case .didDiscover(let id, let name, let rssi, let services, let mfgData):
            let device = DiscoveredDevice(
                identifier: id.uuidString,
                name: name,
                rssi: rssi,
                serviceUUIDs: services,
                manufacturerData: mfgData
            )
            scanContinuation?.yield(device)

        case .didConnect:
            if let cont = connectContinuation {
                connectContinuation = nil
                cont.resume()
            }

        case .didFailToConnect(_, let error):
            if let cont = connectContinuation {
                connectContinuation = nil
                cont.resume(throwing: BLEError.connectionFailed(error ?? "unknown"))
            }

        case .didDisconnect(_, let error):
            if let cont = disconnectContinuation {
                disconnectContinuation = nil
                cont.resume()
            }
            // Also cancel any notification streams
            for (_, cont) in notificationContinuations {
                cont.finish()
            }
            notificationContinuations.removeAll()

            // Fail pending operations
            let connError = BLEError.connectionFailed(error ?? "disconnected")
            if let cont = connectContinuation {
                connectContinuation = nil
                cont.resume(throwing: connError)
            }

        case .didDiscoverServices(_, let uuids, let error):
            if let cont = discoverServicesContinuation {
                discoverServicesContinuation = nil
                if let error = error {
                    cont.resume(throwing: BLEError.operationFailed(error))
                } else {
                    cont.resume(returning: uuids)
                }
            }

        case .didDiscoverCharacteristics(_, let svcUUID, let chars, let error):
            if let cont = discoverCharsContinuations.removeValue(forKey: svcUUID) {
                if let error = error {
                    cont.resume(throwing: BLEError.operationFailed(error))
                } else {
                    cont.resume(returning: chars)
                }
            }

        case .didDiscoverDescriptors(_, let charUUID, let descs, let error):
            if let cont = discoverDescContinuations.removeValue(forKey: charUUID) {
                if let error = error {
                    cont.resume(throwing: BLEError.operationFailed(error))
                } else {
                    cont.resume(returning: descs)
                }
            }

        case .didUpdateValue(_, let charUUID, let value, let error):
            // If there's a one-shot read continuation, fulfill it
            if let cont = readContinuations.removeValue(forKey: charUUID) {
                if let error = error {
                    cont.resume(throwing: BLEError.readFailed(error))
                } else {
                    cont.resume(returning: value ?? Data())
                }
            }
            // If there's a notification stream, yield to it
            else if let streamCont = notificationContinuations[charUUID], let value = value {
                streamCont.yield(value)
            }

        case .didWriteValue(_, let charUUID, let error):
            if let cont = writeContinuations.removeValue(forKey: charUUID) {
                if let error = error {
                    cont.resume(throwing: BLEError.writeFailed(error))
                } else {
                    cont.resume()
                }
            }

        case .didUpdateNotificationState(_, let charUUID, _, let error):
            if let cont = subscribeContinuations.removeValue(forKey: charUUID) {
                if let error = error {
                    cont.resume(throwing: BLEError.subscribeFailed(error))
                } else {
                    cont.resume()
                }
            }
        }
    }
}
