import Foundation
import CoreBluetooth

/// Public facade for BLE central operations.
/// Owns the CBCentralManager, delegate, event queue, and processor.
public final class BLECentral: @unchecked Sendable {
    public static let shared = BLECentral()

    private let cbQueue = DispatchQueue(label: "blew.cb", qos: .userInitiated)
    private let eventQueue = BLEEventQueue(capacity: 1024)
    private let processor: BLEEventProcessor
    let delegate: BLEDelegate
    private var centralManager: CBCentralManager!

    // Connection state
    private let stateLock = NSLock()
    private var connectedPeripheralId: UUID?
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
        processor.start()
    }

    // MARK: - State helpers

    private func ensurePoweredOn() throws {
        stateLock.lock()
        let state = cbState
        stateLock.unlock()
        switch state {
        case .poweredOn:
            return
        case .poweredOff:
            throw BLEError.bluetoothUnavailable("Bluetooth is powered off")
        case .unauthorized:
            throw BLEError.bluetoothUnavailable("Bluetooth access unauthorized")
        case .unsupported:
            throw BLEError.bluetoothUnavailable("Bluetooth is not supported")
        default:
            throw BLEError.bluetoothUnavailable("Bluetooth state: \(state.rawValue)")
        }
    }

    private func waitForPoweredOn(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            stateLock.lock()
            let state = cbState
            stateLock.unlock()
            if state == .poweredOn { return }
            if Date() > deadline {
                throw BLEError.bluetoothUnavailable("Timed out waiting for Bluetooth to power on")
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
    }

    // MARK: - Scan

    public func scan(timeout: TimeInterval = 5.0) async throws -> AsyncStream<DiscoveredDevice> {
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
                CBCentralManagerScanOptionAllowDuplicatesKey: false,
            ])
        }

        // Schedule scan stop -- stops scanning and finishes the stream
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

        return stream
    }

    // MARK: - Connect

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

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            processor.setConnectContinuation(cont)
            cbQueue.async {
                targetPeripheral.delegate = self.delegate
                self.centralManager.connect(targetPeripheral, options: nil)
            }
        }

        stateLock.lock()
        connectedPeripheralId = uuid
        connectedPeripheralName = targetPeripheral.name
        stateLock.unlock()

        // Auto-discover services
        try await discoverAllServices(peripheral: targetPeripheral)
    }

    // MARK: - Disconnect

    public func disconnect() async throws {
        guard let uuid = getConnectedId() else {
            throw BLEError.notConnected
        }

        var peripheral: CBPeripheral?
        cbQueue.sync {
            peripheral = delegate.peripherals[uuid]
        }

        guard let p = peripheral else {
            throw BLEError.notConnected
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            processor.setDisconnectContinuation(cont)
            cbQueue.async {
                self.centralManager.cancelPeripheralConnection(p)
            }
        }

        stateLock.lock()
        connectedPeripheralId = nil
        connectedPeripheralName = nil
        discoveredServices = []
        discoveredCharacteristics = []
        activeSubscriptions = []
        stateLock.unlock()
    }

    // MARK: - Status

    public func status() async -> ConnectionStatus {
        stateLock.lock()
        let s = ConnectionStatus(
            isConnected: connectedPeripheralId != nil,
            deviceId: connectedPeripheralId?.uuidString,
            deviceName: connectedPeripheralName,
            servicesCount: discoveredServices.count,
            characteristicsCount: discoveredCharacteristics.count,
            subscriptionsCount: activeSubscriptions.count,
            lastError: lastError
        )
        stateLock.unlock()
        return s
    }

    // MARK: - GATT Discovery

    public func discoverServices() async throws -> [ServiceInfo] {
        guard let peripheral = try getConnectedPeripheral() else {
            throw BLEError.notConnected
        }

        stateLock.lock()
        let services = discoveredServices
        stateLock.unlock()

        return services.map {
            ServiceInfo(uuid: $0.uuid.uuidString, isPrimary: $0.isPrimary)
        }
    }

    public func discoverTree(includeDescriptors: Bool = false) async throws -> [ServiceTree] {
        guard let peripheral = try getConnectedPeripheral() else {
            throw BLEError.notConnected
        }

        stateLock.lock()
        let services = discoveredServices
        stateLock.unlock()

        var tree: [ServiceTree] = []
        for service in services {
            var charInfos: [CharacteristicInfo] = []
            let chars = service.characteristics ?? []
            for char in chars {
                var descInfos: [DescriptorInfo] = []
                if includeDescriptors {
                    let descUUIDs = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], Error>) in
                        self.processor.setDiscoverDescContinuation(forChar: char.uuid.uuidString, cont)
                        self.cbQueue.async {
                            peripheral.discoverDescriptors(for: char)
                        }
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
        stateLock.lock()
        let chars = discoveredCharacteristics.filter {
            $0.service?.uuid.uuidString.lowercased() == serviceUUID.lowercased()
        }
        stateLock.unlock()

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

        stateLock.lock()
        let char = discoveredCharacteristics.first {
            $0.uuid.uuidString.lowercased() == charUUID.lowercased()
        }
        stateLock.unlock()

        guard let c = char else {
            throw BLEError.characteristicNotFound(charUUID)
        }

        let descUUIDs = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], Error>) in
            processor.setDiscoverDescContinuation(forChar: charUUID.uppercased(), cont)
            cbQueue.async {
                peripheral.discoverDescriptors(for: c)
            }
        }

        return descUUIDs.map { DescriptorInfo(uuid: $0) }
    }

    // MARK: - Read

    public func readCharacteristic(_ charUUID: String) async throws -> Data {
        guard let peripheral = try getConnectedPeripheral() else {
            throw BLEError.notConnected
        }

        stateLock.lock()
        let char = discoveredCharacteristics.first {
            $0.uuid.uuidString.lowercased() == charUUID.lowercased()
        }
        stateLock.unlock()

        guard let c = char else {
            throw BLEError.characteristicNotFound(charUUID)
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            processor.setReadContinuation(forChar: c.uuid.uuidString, cont)
            cbQueue.async {
                peripheral.readValue(for: c)
            }
        }
    }

    // MARK: - Write

    public func writeCharacteristic(_ charUUID: String, data: Data, type: WriteType = .auto) async throws {
        guard let peripheral = try getConnectedPeripheral() else {
            throw BLEError.notConnected
        }

        stateLock.lock()
        let char = discoveredCharacteristics.first {
            $0.uuid.uuidString.lowercased() == charUUID.lowercased()
        }
        stateLock.unlock()

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
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                processor.setWriteContinuation(forChar: c.uuid.uuidString, cont)
                cbQueue.async {
                    peripheral.writeValue(data, for: c, type: cbType)
                }
            }
        } else {
            cbQueue.async {
                peripheral.writeValue(data, for: c, type: cbType)
            }
        }
    }

    // MARK: - Subscribe

    public func subscribe(characteristicUUID charUUID: String) async throws -> AsyncStream<Data> {
        guard let peripheral = try getConnectedPeripheral() else {
            throw BLEError.notConnected
        }

        stateLock.lock()
        let char = discoveredCharacteristics.first {
            $0.uuid.uuidString.lowercased() == charUUID.lowercased()
        }
        stateLock.unlock()

        guard let c = char else {
            throw BLEError.characteristicNotFound(charUUID)
        }

        // Enable notifications
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            processor.setSubscribeContinuation(forChar: c.uuid.uuidString, cont)
            cbQueue.async {
                peripheral.setNotifyValue(true, for: c)
            }
        }

        stateLock.lock()
        activeSubscriptions.insert(charUUID.uppercased())
        stateLock.unlock()

        let stream = AsyncStream<Data> { continuation in
            self.processor.setNotificationContinuation(forChar: c.uuid.uuidString, continuation)
            continuation.onTermination = { _ in
                self.processor.setNotificationContinuation(forChar: c.uuid.uuidString, nil)
                self.cbQueue.async {
                    peripheral.setNotifyValue(false, for: c)
                }
                self.stateLock.lock()
                self.activeSubscriptions.remove(charUUID.uppercased())
                self.stateLock.unlock()
            }
        }

        return stream
    }

    // MARK: - Private helpers

    private func getConnectedId() -> UUID? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connectedPeripheralId
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

    private func discoverAllServices(peripheral: CBPeripheral) async throws {
        let serviceUUIDs = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String], Error>) in
            processor.setDiscoverServicesContinuation(cont)
            cbQueue.async {
                peripheral.discoverServices(nil)
            }
        }

        // Wait for services to be available on the peripheral object
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        var allServices: [CBService] = []
        var allChars: [CBCharacteristic] = []

        let services = peripheral.services ?? []
        allServices = services

        for service in services {
            let chars = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[BLEEvent.DiscoveredCharacteristic], Error>) in
                self.processor.setDiscoverCharsContinuation(forService: service.uuid.uuidString, cont)
                self.cbQueue.async {
                    peripheral.discoverCharacteristics(nil, for: service)
                }
            }
            if let discovered = service.characteristics {
                allChars.append(contentsOf: discovered)
            }
        }

        stateLock.lock()
        discoveredServices = allServices
        discoveredCharacteristics = allChars
        stateLock.unlock()
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
