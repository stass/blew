import Foundation
import CoreBluetooth

/// Events produced by CoreBluetooth delegate callbacks.
/// All CB object data is copied out into value types so the event
/// can safely cross thread boundaries.
public enum BLEEvent: Sendable {
    // Central manager state
    case centralStateChanged(CBManagerState)

    // Scanning
    case didDiscover(
        peripheralId: UUID,
        name: String?,
        rssi: Int,
        serviceUUIDs: [String],
        manufacturerData: Data?
    )

    // Connection
    case didConnect(peripheralId: UUID)
    case didFailToConnect(peripheralId: UUID, error: String?)
    case didDisconnect(peripheralId: UUID, error: String?)

    // Service discovery
    case didDiscoverServices(peripheralId: UUID, serviceUUIDs: [String], error: String?)

    // Characteristic discovery
    case didDiscoverCharacteristics(
        peripheralId: UUID,
        serviceUUID: String,
        characteristics: [DiscoveredCharacteristic],
        error: String?
    )

    // Descriptor discovery
    case didDiscoverDescriptors(
        peripheralId: UUID,
        characteristicUUID: String,
        descriptorUUIDs: [String],
        error: String?
    )

    // Read
    case didUpdateValue(
        peripheralId: UUID,
        characteristicUUID: String,
        value: Data?,
        error: String?
    )

    // Write
    case didWriteValue(
        peripheralId: UUID,
        characteristicUUID: String,
        error: String?
    )

    // Notification state
    case didUpdateNotificationState(
        peripheralId: UUID,
        characteristicUUID: String,
        isNotifying: Bool,
        error: String?
    )

    public struct DiscoveredCharacteristic: Sendable {
        public let uuid: String
        public let properties: CBCharacteristicProperties

        public init(uuid: String, properties: CBCharacteristicProperties) {
            self.uuid = uuid
            self.properties = properties
        }
    }
}
