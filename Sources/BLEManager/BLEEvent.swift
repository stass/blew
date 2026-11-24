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

    /// Queued by `BLEEventProcessor.issueConnect` on blew.cb just before the
    /// CoreBluetooth connect call of `attempt`; CoreBluetooth sends no such
    /// event. Orders the attempt's start with the callbacks around it.
    case connectIssued(ConnectAttempt)
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

    // Write-without-response flow control: the peripheral can accept another
    // write without response (CBPeripheral.canSendWriteWithoutResponse became true)
    case isReadyToSendWriteWithoutResponse(peripheralId: UUID)

    // Notification state
    case didUpdateNotificationState(
        peripheralId: UUID,
        characteristicUUID: String,
        isNotifying: Bool,
        error: String?
    )

    /// The peripheral whose connection the event belongs to; nil for the
    /// events that belong to no connection: the central's state and scan
    /// results.
    var connectionPeripheralId: UUID? {
        switch self {
        case .centralStateChanged, .didDiscover:
            return nil
        case .connectIssued(let attempt):
            return attempt.peripheral
        case .didConnect(let id), .didFailToConnect(let id, _), .didDisconnect(let id, _),
             .didDiscoverServices(let id, _, _), .didDiscoverCharacteristics(let id, _, _, _),
             .didDiscoverDescriptors(let id, _, _, _), .didUpdateValue(let id, _, _, _),
             .didWriteValue(let id, _, _), .isReadyToSendWriteWithoutResponse(let id),
             .didUpdateNotificationState(let id, _, _, _):
            return id
        }
    }

    public struct DiscoveredCharacteristic: Sendable {
        public let uuid: String
        public let properties: CBCharacteristicProperties

        public init(uuid: String, properties: CBCharacteristicProperties) {
            self.uuid = uuid
            self.properties = properties
        }
    }
}
