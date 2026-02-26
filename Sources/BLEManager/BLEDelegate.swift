import Foundation
import CoreBluetooth

/// CoreBluetooth delegate that extracts event data and enqueues to the lock-free queue.
/// All callbacks return immediately after enqueuing.
final class BLEDelegate: NSObject, @unchecked Sendable {
    let queue: BLEEventQueue
    /// Peripherals must be retained to keep the connection alive.
    /// Access from CB's queue only.
    var peripherals: [UUID: CBPeripheral] = [:]

    init(queue: BLEEventQueue) {
        self.queue = queue
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEDelegate: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        queue.enqueue(.centralStateChanged(central.state))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        peripherals[peripheral.identifier] = peripheral

        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString } ?? []
        let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data

        queue.enqueue(.didDiscover(
            peripheralId: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            serviceUUIDs: serviceUUIDs,
            manufacturerData: mfgData
        ))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        queue.enqueue(.didConnect(peripheralId: peripheral.identifier))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        queue.enqueue(.didFailToConnect(
            peripheralId: peripheral.identifier,
            error: error?.localizedDescription
        ))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        queue.enqueue(.didDisconnect(
            peripheralId: peripheral.identifier,
            error: error?.localizedDescription
        ))
    }
}

// MARK: - CBPeripheralDelegate

extension BLEDelegate: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let uuids = peripheral.services?.map { $0.uuid.uuidString } ?? []
        queue.enqueue(.didDiscoverServices(
            peripheralId: peripheral.identifier,
            serviceUUIDs: uuids,
            error: error?.localizedDescription
        ))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let chars = service.characteristics?.map {
            BLEEvent.DiscoveredCharacteristic(
                uuid: $0.uuid.uuidString,
                properties: $0.properties
            )
        } ?? []
        queue.enqueue(.didDiscoverCharacteristics(
            peripheralId: peripheral.identifier,
            serviceUUID: service.uuid.uuidString,
            characteristics: chars,
            error: error?.localizedDescription
        ))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let descs = characteristic.descriptors?.map { $0.uuid.uuidString } ?? []
        queue.enqueue(.didDiscoverDescriptors(
            peripheralId: peripheral.identifier,
            characteristicUUID: characteristic.uuid.uuidString,
            descriptorUUIDs: descs,
            error: error?.localizedDescription
        ))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        queue.enqueue(.didUpdateValue(
            peripheralId: peripheral.identifier,
            characteristicUUID: characteristic.uuid.uuidString,
            value: characteristic.value,
            error: error?.localizedDescription
        ))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        queue.enqueue(.didWriteValue(
            peripheralId: peripheral.identifier,
            characteristicUUID: characteristic.uuid.uuidString,
            error: error?.localizedDescription
        ))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        queue.enqueue(.didUpdateNotificationState(
            peripheralId: peripheral.identifier,
            characteristicUUID: characteristic.uuid.uuidString,
            isNotifying: characteristic.isNotifying,
            error: error?.localizedDescription
        ))
    }
}
