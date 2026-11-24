import Foundation
@preconcurrency import CoreBluetooth

/// Public facade for BLE central operations.
/// Owns the CBCentralManager, delegate, event queue, and processor.
public final class BLECentral: @unchecked Sendable {
    public static let shared = BLECentral()

    private let cbQueue = DispatchQueue(label: "blew.cb", qos: .userInitiated)
    private let eventQueue = BLEEventQueue(capacity: 1024)
    private let processor: BLEEventProcessor
    let delegate: BLEDelegate
    private var centralManager: CBCentralManager!

    // What blew knows about the connection. Which peripheral is connected
    // is the processor's (`processor.connectedPeripheralId`); this caches
    // its name and GATT database, written only while it is connected
    // (`updateConnection`) and cleared when it disconnects.
    private let stateLock = NSLock()
    private var connectedPeripheralName: String?
    private var discoveredServices: [CBService] = []
    private var discoveredCharacteristics: [CBCharacteristic] = []
    private var activeSubscriptions: Set<String> = []
    private var lastError: String?
    private var cbState: CBManagerState = .unknown

    private init() {
        self.delegate = BLEDelegate(queue: eventQueue)
        self.processor = BLEEventProcessor(eventQueue: eventQueue)
        self.centralManager = CBCentralManager(delegate: delegate, queue: cbQueue)

        processor.onStateChange { [weak self] state in
            self?.stateLock.lock()
            self?.cbState = state
            self?.stateLock.unlock()
        }
        processor.onDisconnect { [weak self] _ in
            self?.forgetConnection()
        }
        processor.start()
    }

    // MARK: - State helpers

    private func ensurePoweredOn() throws {
        stateLock.lock()
        let state = cbState
        stateLock.unlock()
        guard state == .poweredOn else { throw BLEError.unavailable(state) }
    }

    private func waitForPoweredOn(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state = stateLock.withLock { cbState }
            if state == .poweredOn { return }
            if Date() > deadline {
                throw BLEError.bluetoothUnavailable("Timed out waiting for Bluetooth to power on")
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    // MARK: - Scan

    public func scan(timeout: TimeInterval? = 5.0, allowDuplicates: Bool = false) async throws -> AsyncStream<DiscoveredDevice> {
        try await waitForPoweredOn(timeout: 5.0)

        let stream = AsyncStream<DiscoveredDevice> { continuation in
            self.processor.setScanContinuation(continuation)
            continuation.onTermination = { @Sendable _ in
                self.cbQueue.async {
                    self.centralManager.stopScan()
                }
                self.processor.setScanContinuation(nil)
            }
        }

        cbQueue.async {
            self.centralManager.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates,
            ])
        }

        // When a timeout is given, schedule a stop after that duration.
        // When timeout is nil the stream runs until the caller cancels or
        // calls stopScan externally (watch mode).
        if let timeout = timeout {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self = self else { return }
                self.cbQueue.async {
                    self.centralManager.stopScan()
                }
                // setScanContinuation(nil) calls finish() on the old continuation,
                // which terminates the `for await` loop in the caller
                self.processor.setScanContinuation(nil)
            }
        }

        return stream
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

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    processor.beginConnect(to: uuid, cont)
                    // A cancel before the wait was registered found nothing to end.
                    if Task.isCancelled {
                        processor.cancelConnect()
                        return
                    }
                    cbQueue.async {
                        // A cancel that ran first ended the wait: start no
                        // connect that no one waits for.
                        guard self.processor.isConnecting(to: uuid) else { return }
                        targetPeripheral.delegate = self.delegate
                        self.centralManager.connect(targetPeripheral, options: nil)
                    }
                }
            } onCancel: {
                self.processor.cancelConnect()
            }
            // A cancel that came just after the device connected: keep no
            // connection the caller gave up on.
            try Task.checkCancellation()

            updateConnection(uuid) {
                connectedPeripheralName = targetPeripheral.name
            }
            // Without its GATT database the connection serves no operation.
            try await discoverAllServices(peripheral: targetPeripheral)
        } catch {
            // A connection whose setup failed is not kept: blew stops serving
            // it at once (a no-op when the connect itself failed), so it is not
            // reported or reused as connected.
            processor.endConnection(to: uuid, BLEError.connectionFailed("connection setup did not complete"))
            // CoreBluetooth keeps a connect pending until it is cancelled, and
            // would connect the device later with no one waiting for it. On
            // blew.cb this runs after any connect queued before the cancel.
            cbQueue.async {
                self.centralManager.cancelPeripheralConnection(targetPeripheral)
            }
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
    /// processor's disconnect callback has forgotten the connection by then.
    private func closeConnection() async throws {
        guard let uuid = getConnectedId() else { return }
        var peripheral: CBPeripheral?
        cbQueue.sync {
            peripheral = delegate.peripherals[uuid]
        }
        guard let p = peripheral else {
            throw BLEError.operationFailed("the connected device \(uuid.uuidString) is missing from the peripheral cache")
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if processor.beginDisconnect(from: uuid, cont) {
                    cbQueue.async {
                        self.centralManager.cancelPeripheralConnection(p)
                    }
                }
            }
        } onCancel: {
            self.processor.cancelDisconnectContinuation()
        }
    }

    /// Update the cached state of the connection to `id`, unless it has
    /// already ended. The processor stops serving a connection before its
    /// disconnect callback takes `stateLock` to clear the cache, so an update
    /// made here is either refused or cleared afterwards.
    private func updateConnection(_ id: UUID, _ update: () -> Void) {
        stateLock.withLock {
            guard processor.connectedPeripheralId == id else { return }
            update()
        }
    }

    /// Clear the cached state after the connection ended, whoever ended it,
    /// so status() reports it and a later connect starts fresh.
    private func forgetConnection() {
        stateLock.withLock {
            connectedPeripheralName = nil
            discoveredServices = []
            discoveredCharacteristics = []
            activeSubscriptions = []
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
                subscriptionsCount: activeSubscriptions.count,
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

        let char = stateLock.withLock {
            discoveredCharacteristics.first {
                $0.uuid.uuidString.lowercased() == charUUID.lowercased()
            }
        }

        guard let c = char else {
            throw BLEError.characteristicNotFound(charUUID)
        }

        return try await request({ .read(characteristic: c.uuid.uuidString, $0) }, to: peripheral) {
            peripheral.readValue(for: c)
        }
    }

    // MARK: - Write

    public func writeCharacteristic(_ charUUID: String, data: Data, type: WriteType = .auto) async throws {
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

        let cbType: CBCharacteristicWriteType
        switch type {
        case .withResponse:
            cbType = .withResponse
        case .withoutResponse:
            cbType = .withoutResponse
        case .auto:
            cbType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        }

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

    /// Enable notifications of `charUUID` and stream its values. The stream
    /// throws the reason when the connection ends (a disconnect, Bluetooth
    /// becoming unavailable); ending the iteration turns notifications off.
    public func subscribe(characteristicUUID charUUID: String) async throws -> AsyncThrowingStream<Data, Error> {
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

        // Enable notifications and wait for the device to confirm. A wait
        // that is given up (cancelled, or stopped by a caller's deadline)
        // after the request went out queues turning notifications off,
        // after the request to turn them on and before any subscribe
        // started after the cancellation. A device that confirms late is
        // then not left notifying a connection that no stream reads, and its
        // late confirmation is the abandoned request's, not a later one's.
        let turnOff: @Sendable () -> Void = {
            if peripheral.state == .connected { peripheral.setNotifyValue(false, for: c) }
        }
        try await request({ .subscribe(characteristic: c.uuid.uuidString, $0) }, to: peripheral, undo: turnOff) {
            peripheral.setNotifyValue(true, for: c)
        }

        stateLock.withLock { _ = activeSubscriptions.insert(charUUID.uppercased()) }

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            self.processor.setNotificationContinuation(forChar: c.uuid.uuidString, continuation)
            continuation.onTermination = { _ in
                self.processor.setNotificationContinuation(forChar: c.uuid.uuidString, nil)
                self.cbQueue.async {
                    peripheral.setNotifyValue(false, for: c)
                }
                self.stateLock.withLock { _ = self.activeSubscriptions.remove(charUUID.uppercased()) }
            }
        }

        return stream
    }

    // MARK: - Private helpers

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
    /// queued as abandoned until its answer arrives, and `undo`, the
    /// CoreBluetooth call that reverses it, is queued on blew.cb, after
    /// `call` (see `BLEEventProcessor.cancel`).
    private func request<T>(
        _ makeRequest: (CheckedContinuation<T, Error>) -> CentralRequest,
        to peripheral: CBPeripheral,
        undo: (@Sendable () -> Void)? = nil,
        call: @escaping @Sendable () -> Void
    ) async throws -> T {
        let processor = self.processor
        let ticket = processor.makeTicket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                processor.submit(ticket, makeRequest(cont), to: peripheral.identifier, on: cbQueue, call: call)
            }
        } onCancel: {
            let cbQueue = self.cbQueue
            processor.cancel(ticket, undo: undo.map { undo in { cbQueue.async(execute: undo) } })
        }
    }

    private func discoverAllServices(peripheral: CBPeripheral) async throws {
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

        updateConnection(peripheral.identifier) {
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
        var list: [String] = []
        if props.contains(.read) { list.append("read") }
        if props.contains(.write) { list.append("write") }
        if props.contains(.writeWithoutResponse) { list.append("writeNoResp") }
        if props.contains(.notify) { list.append("notify") }
        if props.contains(.indicate) { list.append("indicate") }
        if props.contains(.broadcast) { list.append("broadcast") }
        if props.contains(.authenticatedSignedWrites) { list.append("signedWrite") }
        if props.contains(.extendedProperties) { list.append("extended") }
        return list
    }
}
