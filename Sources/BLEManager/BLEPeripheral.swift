import Foundation
@preconcurrency import CoreBluetooth

/// Public facade for BLE peripheral (GATT server) operations.
///
/// Owns the `CBPeripheralManager`, delegate, and value store.
/// All CoreBluetooth calls are serialised onto `blew.pm`.
public final class BLEPeripheral: @unchecked Sendable {
    public static let shared = BLEPeripheral()

    private let pmQueue = DispatchQueue(label: "blew.pm", qos: .userInitiated)
    private let store: GATTStore
    let delegate: BLEPeripheralDelegate
    private var peripheralManager: CBPeripheralManager!

    // State (guarded by stateLock)
    private let stateLock = NSLock()
    private var pmState: CBManagerState = .unknown
    private var _isAdvertising = false
    private var _advertisedName: String?
    private var registeredCharacteristics: [String: CBMutableCharacteristic] = [:]
    private var registeredServices: [CBMutableService] = []

    private init() {
        self.store = GATTStore()
        self.delegate = BLEPeripheralDelegate(store: store)
        self.peripheralManager = CBPeripheralManager(delegate: delegate, queue: pmQueue)
    }

    // MARK: - Public API

    /// Configure GATT services and register them with the peripheral manager.
    /// Must be called before `startAdvertising`. Replaces any previously configured services.
    public func configure(services: [ServiceDefinition]) async throws {
        try await waitForPoweredOn(timeout: 5.0)

        // Remove previously added services
        pmQueue.sync {
            self.peripheralManager.removeAllServices()
        }

        stateLock.withLock {
            registeredCharacteristics = [:]
            registeredServices = []
        }

        store.reset()

        for svcDef in services {
            // Services with no characteristics are advertise-only: they don't need
            // to be registered with the peripheral manager (and CoreBluetooth will
            // reject adding a standard Bluetooth SIG service UUID with no GATT content).
            guard !svcDef.characteristics.isEmpty else { continue }

            let mutableChars = buildMutableCharacteristics(from: svcDef.characteristics)
            let serviceUUID = CBUUID(string: svcDef.uuid)
            let mutableService = CBMutableService(type: serviceUUID, primary: svcDef.primary)
            mutableService.characteristics = mutableChars.map { $0.char }

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                delegate.setServiceContinuation(uuid: svcDef.uuid, cont)
                pmQueue.async {
                    self.peripheralManager.add(mutableService)
                }
            }

            stateLock.withLock {
                for mc in mutableChars {
                    registeredCharacteristics[mc.uuid.uppercased()] = mc.char
                }
                registeredServices.append(mutableService)
            }
        }
    }

    /// Start advertising with the given local name and service UUIDs.
    ///
    /// CoreBluetooth only allows `CBAdvertisementDataLocalNameKey` and
    /// `CBAdvertisementDataServiceUUIDsKey` in the advertisement dictionary.
    /// Manufacturer data and other ADV fields are not supported.
    public func startAdvertising(name: String, serviceUUIDs: [String]) async throws {
        try await waitForPoweredOn(timeout: 5.0)

        var adData: [String: Any] = [
            CBAdvertisementDataLocalNameKey: name,
        ]
        if !serviceUUIDs.isEmpty {
            adData[CBAdvertisementDataServiceUUIDsKey] = serviceUUIDs.map { CBUUID(string: $0) }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.setAdvertisingContinuation(cont)
            pmQueue.async {
                self.peripheralManager.startAdvertising(adData)
            }
        }

        stateLock.withLock {
            _isAdvertising = true
            _advertisedName = name
        }
    }

    /// Stop advertising. Does not remove registered services.
    public func stopAdvertising() {
        pmQueue.async {
            self.peripheralManager.stopAdvertising()
        }
        stateLock.lock()
        _isAdvertising = false
        stateLock.unlock()
    }

    /// Update the stored value of a characteristic. Sends a notification to all
    /// subscribed centrals if the characteristic supports notify or indicate.
    public func updateValue(_ data: Data, forCharacteristic uuid: String) throws {
        let key = uuid.uppercased()
        store.setValue(data, for: key)

        stateLock.lock()
        let char = registeredCharacteristics[key]
        stateLock.unlock()

        guard let mutableChar = char else {
            throw BLEError.characteristicNotFound(uuid)
        }

        let subscribers = store.subscriberList(for: key)
        guard !subscribers.isEmpty else { return }

        pmQueue.async {
            _ = self.peripheralManager.updateValue(data, for: mutableChar, onSubscribedCentrals: nil)
        }
    }

    /// Returns an `AsyncStream` of peripheral events (read/write requests, subscriptions, etc.).
    /// Only one stream is active at a time; calling this again replaces the previous stream.
    public func events() -> AsyncStream<PeripheralEvent> {
        AsyncStream<PeripheralEvent> { continuation in
            delegate.setEventContinuation(continuation)
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.delegate.setEventContinuation(nil)
            }
        }
    }

    /// Synchronous snapshot of peripheral state for status display.
    public func peripheralStatus() -> PeripheralStatus {
        stateLock.lock()
        let advertising = _isAdvertising
        let name = _advertisedName
        let svcCount = registeredServices.count
        let charCount = registeredCharacteristics.count
        stateLock.unlock()
        let subCount = store.totalSubscriberCount()
        return PeripheralStatus(
            isAdvertising: advertising,
            advertisedName: name,
            serviceCount: svcCount,
            characteristicCount: charCount,
            subscriberCount: subCount
        )
    }

    public func isAdvertising() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isAdvertising
    }

    /// Return all registered characteristic UUIDs (for REPL tab completion).
    public func knownCharacteristicUUIDs() -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(registeredCharacteristics.keys)
    }

    // MARK: - Private helpers

    private struct MutableCharEntry {
        let uuid: String
        let char: CBMutableCharacteristic
    }

    private func buildMutableCharacteristics(
        from defs: [CharacteristicDefinition]
    ) -> [MutableCharEntry] {
        defs.map { def in
            let props = cbProperties(from: def.properties)
            let perms = cbPermissions(from: def.properties)
            let charUUID = CBUUID(string: def.uuid)
            let mutableChar = CBMutableCharacteristic(
                type: charUUID,
                properties: props,
                value: nil,
                permissions: perms
            )
            if let descUUIDs = def.descriptors {
                mutableChar.descriptors = descUUIDs.map {
                    CBMutableDescriptor(type: CBUUID(string: $0), value: nil)
                }
            }
            return MutableCharEntry(uuid: def.uuid, char: mutableChar)
        }
    }

    private func cbProperties(from props: [CharacteristicProperty]) -> CBCharacteristicProperties {
        var result: CBCharacteristicProperties = []
        for p in props {
            switch p {
            case .read:                 result.insert(.read)
            case .write:                result.insert(.write)
            case .writeWithoutResponse: result.insert(.writeWithoutResponse)
            case .notify:               result.insert(.notify)
            case .indicate:             result.insert(.indicate)
            }
        }
        return result
    }

    private func cbPermissions(from props: [CharacteristicProperty]) -> CBAttributePermissions {
        var result: CBAttributePermissions = []
        if props.contains(.read) { result.insert(.readable) }
        if props.contains(.write) || props.contains(.writeWithoutResponse) {
            result.insert(.writeable)
        }
        return result
    }

    private func waitForPoweredOn(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state: CBManagerState = pmQueue.sync { peripheralManager.state }
            if state == .poweredOn { return }
            if Date() > deadline {
                throw BLEError.peripheralUnavailable("Timed out waiting for Bluetooth to power on")
            }
            switch state {
            case .poweredOff:
                throw BLEError.peripheralUnavailable("Bluetooth is powered off")
            case .unauthorized:
                throw BLEError.peripheralUnavailable("Bluetooth access unauthorized")
            case .unsupported:
                throw BLEError.peripheralUnavailable("Bluetooth is not supported")
            default:
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
    }

}
