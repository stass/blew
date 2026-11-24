import Foundation
import os
@preconcurrency import CoreBluetooth

/// Public facade for BLE central operations.
/// Owns the CBCentralManager, delegate, event queue, and processor.
public final class BLECentral: @unchecked Sendable {
    public static let shared: BLECentral = {
        let instance = BLECentral()
        sharedCreated.withLock { $0 = true }
        return instance
    }()

    private static let sharedCreated = OSAllocatedUnfairLock(initialState: false)

    /// `shared` once something has used it, and nil before: for blew's exit
    /// cleanup, which must not create a `CBCentralManager` (and ask for
    /// Bluetooth access) only to find nothing to clean up.
    public static var sharedIfCreated: BLECentral? {
        sharedCreated.withLock { $0 } ? shared : nil
    }

    private let cbQueue = DispatchQueue(label: "blew.cb", qos: .userInitiated)
    private let eventQueue = BLEEventQueue()
    private let processor: BLEEventProcessor
    let delegate: BLEDelegate
    private var centralManager: CBCentralManager!

    // What blew knows about the connection. Which peripheral is connected
    // is the processor's (`processor.connectedPeripheralId`); this caches
    // its name and GATT database, written only while it is connected
    // (`updateConnection`) and cleared when it disconnects.
    private let stateLock = NSLock()
    /// The attempt whose connection the cache describes.
    private var cachedAttempt: ConnectAttempt?
    private var connectedPeripheralName: String?
    private var discoveredServices: [CBService] = []
    private var discoveredCharacteristics: [CBCharacteristic] = []
    private var lastError: String?

    private init() {
        self.delegate = BLEDelegate(queue: eventQueue)
        self.processor = BLEEventProcessor(eventQueue: eventQueue)
        self.centralManager = CBCentralManager(delegate: delegate, queue: cbQueue)

        processor.onLinkEnded { [weak self] attempt in
            self?.forgetConnection(attempt)
        }
        // A connection blew gave up (a cancelled, replaced or timed-out
        // connect, a failed setup) may still be held or pending in
        // CoreBluetooth, which would connect the device later with no one
        // waiting for it.
        processor.onCancelConnection(on: cbQueue) { [weak self] peripheral in
            guard let self, let p = self.delegate.peripherals[peripheral] else { return }
            self.centralManager.cancelPeripheralConnection(p)
        }
        processor.start()
    }

    // MARK: - State helpers

    /// Scan results dropped because the event queue was full of events the
    /// processor had not yet handled (an `allowDuplicates` scan flood).
    public var droppedScanResults: Int {
        eventQueue.droppedScanResults
    }

    /// Poll the state until poweredOn. A state that will not change by
    /// itself fails at once; the wait is cancellable and has a deadline.
    private func waitForPoweredOn(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state = processor.centralState
            if state == .poweredOn { return }
            if let error = BLEError.persistentlyUnavailable(state) { throw error }
            if Date() > deadline {
                throw BLEError.bluetoothUnavailable("Timed out waiting for Bluetooth to power on")
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    // MARK: - Scan

    /// Scan for `timeout` seconds, or until the stream's reader stops when
    /// it is nil (`scan -w`). The stream finishes when the time runs out and
    /// throws when the scan ends otherwise: bluetoothUnavailable when
    /// Bluetooth leaves poweredOn, operationFailed when a newer scan
    /// replaces it. Only this scan's deadline and reader end it.
    public func scan(timeout: TimeInterval? = 5.0, allowDuplicates: Bool = false) async throws
        -> ScanStream
    {
        try await waitForPoweredOn(timeout: 5.0)

        return processor.beginScan(timeout: timeout, on: cbQueue, start: {
            self.centralManager.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates,
            ])
        }, stop: {
            self.centralManager.stopScan()
        })
    }

    // MARK: - Connect

    /// Connect to `deviceId` and discover its GATT database. blew holds one
    /// connection: the current one is disconnected first, also when it is to
    /// this device, so a connect always starts afresh.
    public func connect(deviceId: String, timeout: TimeInterval = 10.0) async throws {
        try await waitForPoweredOn(timeout: 5.0)

        guard let uuid = UUID(uuidString: deviceId) else {
            throw BLEError.deviceNotFound(deviceId)
        }

        // Look up peripheral from delegate's cache
        var peripheral: CBPeripheral?
        cbQueue.sync {
            peripheral = delegate.peripherals[uuid]
        }

        if peripheral == nil {
            cbQueue.sync {
                let knownPeripherals = self.centralManager.retrievePeripherals(withIdentifiers: [uuid])
                peripheral = knownPeripherals.first
                if let p = peripheral {
                    self.delegate.peripherals[uuid] = p
                }
            }
        }

        guard let targetPeripheral = peripheral else {
            throw BLEError.deviceNotFound(deviceId)
        }

        try await closeConnection()

        let processor = self.processor
        let attempt = processor.makeConnectAttempt(to: uuid)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    processor.beginConnect(attempt, timeout: timeout, on: cbQueue, cont)
                    // A cancel before the wait was registered found nothing to end.
                    if Task.isCancelled {
                        processor.cancelConnect(attempt)
                        return
                    }
                    cbQueue.async {
                        // A cancel or deadline that came first ended the
                        // wait: start no connect that no one waits for.
                        processor.issueConnect(attempt) {
                            targetPeripheral.delegate = self.delegate
                            self.centralManager.connect(targetPeripheral, options: nil)
                        }
                    }
                }
            } onCancel: {
                processor.cancelConnect(attempt)
            }
            // A cancel that came just after the device connected: keep no
            // connection the caller gave up on.
            try Task.checkCancellation()

            updateConnection(attempt) {
                connectedPeripheralName = targetPeripheral.name
            }
            // Without its GATT database the connection serves no operation.
            try await discoverAllServices(peripheral: targetPeripheral, attempt: attempt)
        } catch {
            // A connection whose setup failed is not kept: blew stops serving
            // it at once (a no-op when the connect itself failed), so it is not
            // reported or reused as connected, and the link-ended callback
            // cancels it in CoreBluetooth.
            processor.endConnection(attempt, BLEError.connectionFailed("connection setup did not complete"))
            throw error
        }
    }

    // MARK: - Disconnect

    public func disconnect() async throws {
        guard getConnectedId() != nil else {
            throw BLEError.notConnected
        }
        try await closeConnection()
    }

    /// Disconnect the connected device, if any, and wait until it has. The
    /// processor's link-ended callback has forgotten the connection by then.
    private func closeConnection() async throws {
        guard let uuid = getConnectedId() else { return }
        var peripheral: CBPeripheral?
        cbQueue.sync {
            peripheral = delegate.peripherals[uuid]
        }
        guard let p = peripheral else {
            throw BLEError.operationFailed("the connected device \(uuid.uuidString) is missing from the peripheral cache")
        }

        let processor = self.processor
        let wait = processor.makeDisconnectWait()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if processor.beginDisconnect(wait, from: uuid, cont) {
                    // A cancel before the wait was registered found nothing
                    // to end; the disconnect still goes out.
                    if Task.isCancelled { processor.cancelDisconnect(wait) }
                    cbQueue.async {
                        self.centralManager.cancelPeripheralConnection(p)
                    }
                }
            }
        } onCancel: {
            processor.cancelDisconnect(wait)
        }
    }

    /// Update the cached state of the connection `attempt` made, unless it
    /// has already ended. The processor stops serving a connection before
    /// its link-ended callback takes `stateLock` to clear the cache, so an
    /// update made here is either refused or cleared afterwards.
    private func updateConnection(_ attempt: ConnectAttempt, _ update: () -> Void) {
        stateLock.withLock {
            guard processor.isConnected(attempt) else { return }
            cachedAttempt = attempt
            update()
        }
    }

    /// Clear the cached state after the connection ended, whoever ended it,
    /// so status() reports it and a later connect starts fresh.
    private func forgetConnection(_ attempt: ConnectAttempt) {
        stateLock.withLock {
            // A late callback of an earlier attempt leaves a newer one's
            // cache alone.
            guard cachedAttempt == nil || cachedAttempt == attempt else { return }
            cachedAttempt = nil
            connectedPeripheralName = nil
            discoveredServices = []
            discoveredCharacteristics = []
        }
    }

    // MARK: - Status

    public func status() async -> ConnectionStatus {
        stateLock.withLock {
            guard let id = processor.connectedPeripheralId else {
                return ConnectionStatus(isConnected: false, lastError: lastError)
            }
            return ConnectionStatus(
                isConnected: true,
                deviceId: id.uuidString,
                deviceName: connectedPeripheralName,
                servicesCount: discoveredServices.count,
                characteristicsCount: discoveredCharacteristics.count,
                subscriptionsCount: processor.subscribedCharacteristicCount,
                lastError: lastError
            )
        }
    }

    // MARK: - GATT Discovery

    public func discoverServices() async throws -> [ServiceInfo] {
        guard try getConnectedPeripheral() != nil else {
            throw BLEError.notConnected
        }

        let services = stateLock.withLock { discoveredServices }

        return services.map {
            ServiceInfo(uuid: $0.uuid.uuidString, isPrimary: $0.isPrimary)
        }
    }

    public func discoverTree(includeDescriptors: Bool = false) async throws -> [ServiceTree] {
        guard let peripheral = try getConnectedPeripheral() else {
            throw BLEError.notConnected
        }

        let services = stateLock.withLock { discoveredServices }

        var tree: [ServiceTree] = []
        for service in services {
            var charInfos: [CharacteristicInfo] = []
            let chars = service.characteristics ?? []
            for char in chars {
                var descInfos: [DescriptorInfo] = []
                if includeDescriptors {
                    let descUUIDs = try await request({ .discoverDescriptors(characteristic: char.uuid.uuidString, $0) },
                                                      to: peripheral) {
                        peripheral.discoverDescriptors(for: char)
                    }
                    descInfos = descUUIDs.map { DescriptorInfo(uuid: $0) }
                }
                charInfos.append(CharacteristicInfo(
                    uuid: char.uuid.uuidString,
                    properties: propertiesList(char.properties),
                    descriptors: descInfos
                ))
            }
            tree.append(ServiceTree(
                uuid: service.uuid.uuidString,
                isPrimary: service.isPrimary,
                characteristics: charInfos
            ))
        }
        return tree
    }

    public func discoverCharacteristics(forService serviceUUID: String) async throws -> [CharacteristicInfo] {
        let chars = stateLock.withLock {
            discoveredCharacteristics.filter {
                $0.service?.uuid.uuidString.lowercased() == serviceUUID.lowercased()
            }
        }

        if chars.isEmpty {
            throw BLEError.serviceNotFound(serviceUUID)
        }

        return chars.map {
            CharacteristicInfo(uuid: $0.uuid.uuidString, properties: propertiesList($0.properties))
        }
    }

    public func discoverDescriptors(forCharacteristic charUUID: String) async throws -> [DescriptorInfo] {
        guard let peripheral = try getConnectedPeripheral() else {
            throw BLEError.notConnected
        }

        let char = stateLock.withLock {
            discoveredCharacteristics.first {
                $0.uuid.uuidString.lowercased() == charUUID.lowercased()
            }
        }

        guard let c = char else {
            throw BLEError.characteristicNotFound(charUUID)
        }

        let descUUIDs = try await request({ .discoverDescriptors(characteristic: c.uuid.uuidString, $0) },
                                          to: peripheral) {
            peripheral.discoverDescriptors(for: c)
        }

        return descUUIDs.map { DescriptorInfo(uuid: $0) }
    }

    // MARK: - Read

    public func readCharacteristic(_ charUUID: String) async throws -> Data {
        guard let peripheral = try getConnectedPeripheral() else {
            throw BLEError.notConnected
        }
        let c = try characteristic(charUUID)
        try CharacteristicAccess.checkRead(c.properties, of: c.uuid.uuidString)

        return try await request({ .read(characteristic: c.uuid.uuidString, $0) }, to: peripheral) {
            peripheral.readValue(for: c)
        }
    }

    // MARK: - Write

    /// Write `data` to `charUUID`. A write type the characteristic does not
    /// allow, or a value longer than one write of that type carries, is
    /// refused before it is issued (`CharacteristicAccess`).
    public func writeCharacteristic(_ charUUID: String, data: Data, type: WriteType = .auto) async throws {
        guard let peripheral = try getConnectedPeripheral() else {
            throw BLEError.notConnected
        }
        let c = try characteristic(charUUID)
        let cbType = try CharacteristicAccess.writeType(type, c.properties, of: c.uuid.uuidString)
        let maximum = cbQueue.sync { peripheral.maximumWriteValueLength(for: cbType) }
        try CharacteristicAccess.checkWriteLength(data.count, maximum: maximum, of: c.uuid.uuidString)

        if cbType == .withResponse {
            try await request({ .write(characteristic: c.uuid.uuidString, $0) }, to: peripheral) {
                peripheral.writeValue(data, for: c, type: .withResponse)
            }
        } else {
            // CoreBluetooth drops a write without response issued while
            // canSendWriteWithoutResponse is false, so the write waits until
            // it is ready. The check and the write run in one blew.cb block,
            // so no other write takes the room in between; the poll runs at
            // once and again on every ready event.
            let processor = self.processor
            let cbQueue = self.cbQueue
            let ticket = processor.makeTicket()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    processor.waitToWrite(ticket, cont, to: peripheral.identifier) {
                        cbQueue.async {
                            guard peripheral.canSendWriteWithoutResponse else { return }
                            processor.sendIfWaiting(ticket) {
                                peripheral.writeValue(data, for: c, type: .withoutResponse)
                            }
                        }
                    }
                }
            } onCancel: {
                processor.cancel(ticket)
            }
        }
    }

    /// Largest value a single write of the given kind carries on the current
    /// connection. Without response it is the negotiated ATT MTU minus 3.
    public func maximumWriteLength(withResponse: Bool) throws -> Int {
        guard let peripheral = try getConnectedPeripheral() else {
            throw BLEError.notConnected
        }
        return cbQueue.sync {
            peripheral.maximumWriteValueLength(for: withResponse ? .withResponse : .withoutResponse)
        }
    }

    // MARK: - Subscribe

    /// Subscribe to `charUUID`'s notifications (or indications) and stream
    /// its values, once the device has confirmed them on. Several
    /// subscribers of one characteristic each get their own stream of every
    /// value; notifications are turned on for the first and off when the
    /// last one's stream ends (`NotificationSubscriptions`). The stream is
    /// registered before notifications are turned on, so none is lost after
    /// the confirmation, and it throws the reason when the connection ends
    /// (a disconnect, Bluetooth becoming unavailable). A subscribe given up
    /// (cancelled, or stopped by a caller's deadline) leaves at once; a
    /// stream that is dropped unread also leaves.
    public func subscribe(characteristicUUID charUUID: String) async throws -> NotificationStream {
        guard let peripheral = try getConnectedPeripheral() else {
            throw BLEError.notConnected
        }
        let c = try characteristic(charUUID)
        let uuid = c.uuid.uuidString
        try CharacteristicAccess.checkSubscribe(c.properties, of: uuid)

        let processor = self.processor
        let cbQueue = self.cbQueue
        let id = processor.makeSubscriberID()
        let stream = NotificationStream { processor.unsubscribe(id) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (confirmation: CheckedContinuation<Void, Error>) in
                processor.subscribe(id, to: uuid, stream: stream.sink, confirmation: confirmation,
                                    peripheral: peripheral.identifier, on: cbQueue) { enable in
                    peripheral.setNotifyValue(enable, for: c)
                }
            }
        } onCancel: {
            processor.unsubscribe(id)
        }
        return stream
    }

    // MARK: - Private helpers

    /// The discovered characteristic `uuid` names, in any case.
    private func characteristic(_ uuid: String) throws -> CBCharacteristic {
        let found = stateLock.withLock {
            discoveredCharacteristics.first { $0.uuid.uuidString.lowercased() == uuid.lowercased() }
        }
        guard let found else { throw BLEError.characteristicNotFound(uuid) }
        return found
    }

    private func getConnectedId() -> UUID? {
        processor.connectedPeripheralId
    }

    private func getConnectedPeripheral() throws -> CBPeripheral? {
        guard let uuid = getConnectedId() else {
            throw BLEError.notConnected
        }
        var peripheral: CBPeripheral?
        cbQueue.sync {
            peripheral = delegate.peripherals[uuid]
        }
        return peripheral
    }

    /// Issue one GATT request to the connected `peripheral` and wait for the
    /// callback that answers it. `call`, the CoreBluetooth call, runs on
    /// blew.cb once the processor has queued the request, unless the wait
    /// was cancelled first or the peripheral is no longer connected. A wait
    /// cancelled after the request went out ends at once; the request stays
    /// queued as abandoned until its answer arrives (see
    /// `BLEEventProcessor.cancel`).
    private func request<T>(
        _ makeRequest: (CheckedContinuation<T, Error>) -> CentralRequest,
        to peripheral: CBPeripheral,
        call: @escaping @Sendable () -> Void
    ) async throws -> T {
        let processor = self.processor
        let ticket = processor.makeTicket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                processor.submit(ticket, makeRequest(cont), to: peripheral.identifier, on: cbQueue, call: call)
            }
        } onCancel: {
            processor.cancel(ticket)
        }
    }

    private func discoverAllServices(peripheral: CBPeripheral, attempt: ConnectAttempt) async throws {
        _ = try await request({ .discoverServices($0) }, to: peripheral) {
            peripheral.discoverServices(nil)
        }

        // Wait for services to be available on the peripheral object
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        var allServices: [CBService] = []
        var allChars: [CBCharacteristic] = []

        let services = peripheral.services ?? []
        allServices = services

        for service in services {
            _ = try await request({ .discoverCharacteristics(service: service.uuid.uuidString, $0) },
                                  to: peripheral) {
                peripheral.discoverCharacteristics(nil, for: service)
            }
            if let discovered = service.characteristics {
                allChars.append(contentsOf: discovered)
            }
        }

        updateConnection(attempt) {
            discoveredServices = allServices
            discoveredCharacteristics = allChars
        }
    }

    // MARK: - Synchronous accessors for completion

    public func knownCharacteristicUUIDs() -> [String] {
        stateLock.lock()
        let uuids = discoveredCharacteristics.map { $0.uuid.uuidString }
        stateLock.unlock()
        return uuids
    }

    public func knownServiceUUIDs() -> [String] {
        stateLock.lock()
        let uuids = discoveredServices.map { $0.uuid.uuidString }
        stateLock.unlock()
        return uuids
    }

    private func propertiesList(_ props: CBCharacteristicProperties) -> [String] {
        CharacteristicAccess.propertyNames(props)
    }
}
