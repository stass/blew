import Foundation
import CoreBluetooth

/// Events emitted by the peripheral manager delegate.
/// All CB object data is copied out into value types so events
/// can safely cross thread boundaries.
public enum PeripheralEvent: Sendable {
    case stateChanged(CBManagerState)
    case advertisingStarted(error: String?)
    case serviceAdded(uuid: String, error: String?)
    case centralConnected(centralId: String)
    case centralDisconnected(centralId: String)
    case readRequest(centralId: String, characteristicUUID: String)
    case writeRequest(centralId: String, characteristicUUID: String, value: Data)
    case subscribed(centralId: String, characteristicUUID: String)
    case unsubscribed(centralId: String, characteristicUUID: String)
    case notificationSent(characteristicUUID: String, centralCount: Int)
}
