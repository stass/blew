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

extension PeripheralEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, state, error, uuid, centralId, characteristicUUID, value, centralCount
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stateChanged(let state):
            try container.encode("stateChanged", forKey: .type)
            try container.encode(Self.stateName(state), forKey: .state)
        case .advertisingStarted(let error):
            try container.encode("advertisingStarted", forKey: .type)
            try container.encodeIfPresent(error, forKey: .error)
        case .serviceAdded(let uuid, let error):
            try container.encode("serviceAdded", forKey: .type)
            try container.encode(uuid, forKey: .uuid)
            try container.encodeIfPresent(error, forKey: .error)
        case .centralConnected(let centralId):
            try container.encode("centralConnected", forKey: .type)
            try container.encode(centralId, forKey: .centralId)
        case .centralDisconnected(let centralId):
            try container.encode("centralDisconnected", forKey: .type)
            try container.encode(centralId, forKey: .centralId)
        case .readRequest(let centralId, let charUUID):
            try container.encode("readRequest", forKey: .type)
            try container.encode(centralId, forKey: .centralId)
            try container.encode(charUUID, forKey: .characteristicUUID)
        case .writeRequest(let centralId, let charUUID, let data):
            try container.encode("writeRequest", forKey: .type)
            try container.encode(centralId, forKey: .centralId)
            try container.encode(charUUID, forKey: .characteristicUUID)
            try container.encode(data.map { String(format: "%02x", $0) }.joined(), forKey: .value)
        case .subscribed(let centralId, let charUUID):
            try container.encode("subscribed", forKey: .type)
            try container.encode(centralId, forKey: .centralId)
            try container.encode(charUUID, forKey: .characteristicUUID)
        case .unsubscribed(let centralId, let charUUID):
            try container.encode("unsubscribed", forKey: .type)
            try container.encode(centralId, forKey: .centralId)
            try container.encode(charUUID, forKey: .characteristicUUID)
        case .notificationSent(let charUUID, let count):
            try container.encode("notificationSent", forKey: .type)
            try container.encode(charUUID, forKey: .characteristicUUID)
            try container.encode(count, forKey: .centralCount)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "stateChanged":
            let name = try container.decode(String.self, forKey: .state)
            self = .stateChanged(Self.stateFromName(name))
        case "advertisingStarted":
            self = .advertisingStarted(error: try container.decodeIfPresent(String.self, forKey: .error))
        case "serviceAdded":
            self = .serviceAdded(
                uuid: try container.decode(String.self, forKey: .uuid),
                error: try container.decodeIfPresent(String.self, forKey: .error))
        case "centralConnected":
            self = .centralConnected(centralId: try container.decode(String.self, forKey: .centralId))
        case "centralDisconnected":
            self = .centralDisconnected(centralId: try container.decode(String.self, forKey: .centralId))
        case "readRequest":
            self = .readRequest(
                centralId: try container.decode(String.self, forKey: .centralId),
                characteristicUUID: try container.decode(String.self, forKey: .characteristicUUID))
        case "writeRequest":
            let hex = try container.decode(String.self, forKey: .value)
            var data = Data()
            var i = hex.startIndex
            while i < hex.endIndex {
                let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
                if let byte = UInt8(hex[i..<next], radix: 16) { data.append(byte) }
                i = next
            }
            self = .writeRequest(
                centralId: try container.decode(String.self, forKey: .centralId),
                characteristicUUID: try container.decode(String.self, forKey: .characteristicUUID),
                value: data)
        case "subscribed":
            self = .subscribed(
                centralId: try container.decode(String.self, forKey: .centralId),
                characteristicUUID: try container.decode(String.self, forKey: .characteristicUUID))
        case "unsubscribed":
            self = .unsubscribed(
                centralId: try container.decode(String.self, forKey: .centralId),
                characteristicUUID: try container.decode(String.self, forKey: .characteristicUUID))
        case "notificationSent":
            self = .notificationSent(
                characteristicUUID: try container.decode(String.self, forKey: .characteristicUUID),
                centralCount: try container.decode(Int.self, forKey: .centralCount))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                debugDescription: "Unknown PeripheralEvent type: \(type)")
        }
    }

    private static func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn:    return "poweredOn"
        case .poweredOff:   return "poweredOff"
        case .resetting:    return "resetting"
        case .unauthorized: return "unauthorized"
        case .unsupported:  return "unsupported"
        case .unknown:      return "unknown"
        @unknown default:   return "unknown"
        }
    }

    private static func stateFromName(_ name: String) -> CBManagerState {
        switch name {
        case "poweredOn":    return .poweredOn
        case "poweredOff":   return .poweredOff
        case "resetting":    return .resetting
        case "unauthorized": return .unauthorized
        case "unsupported":  return .unsupported
        default:             return .unknown
        }
    }
}
