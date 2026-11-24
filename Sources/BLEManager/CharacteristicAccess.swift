import Foundation
import CoreBluetooth

/// The requests a characteristic's properties allow, checked before a
/// request reaches CoreBluetooth. CoreBluetooth may drop a request they do
/// not allow without any callback; requests are matched to callbacks in
/// issue order, so one unanswered request would make every later request
/// on the characteristic take its predecessor's answer until the
/// disconnect. A refused request fails with the same error, and the same
/// exit code (5), as one the device refuses.
enum CharacteristicAccess {
    static func checkRead(_ properties: CBCharacteristicProperties, of uuid: String) throws {
        guard properties.contains(.read) else {
            throw BLEError.readFailed("characteristic \(uuid) is not readable (\(describe(properties)))")
        }
    }

    /// The write type to use for `requested`: `.auto` is without response
    /// when the characteristic allows it, with response otherwise.
    static func writeType(_ requested: WriteType, _ properties: CBCharacteristicProperties,
                          of uuid: String) throws -> CBCharacteristicWriteType {
        let withResponse = properties.contains(.write)
        let withoutResponse = properties.contains(.writeWithoutResponse)
        switch requested {
        case .withResponse where withResponse: return .withResponse
        case .withoutResponse where withoutResponse: return .withoutResponse
        case .auto where withoutResponse: return .withoutResponse
        case .auto where withResponse: return .withResponse
        case .withResponse:
            throw BLEError.writeFailed("characteristic \(uuid) does not take writes with response (\(describe(properties)))")
        case .withoutResponse:
            throw BLEError.writeFailed("characteristic \(uuid) does not take writes without response (\(describe(properties)))")
        case .auto:
            throw BLEError.writeFailed("characteristic \(uuid) is not writable (\(describe(properties)))")
        }
    }

    /// `maximum` is `maximumWriteValueLength` for the write type: the ATT
    /// MTU minus 3 without response, 512 (a long write) with response.
    static func checkWriteLength(_ length: Int, maximum: Int, of uuid: String) throws {
        guard length <= maximum else {
            throw BLEError.writeFailed("\(length) bytes exceeds the \(maximum)-byte maximum for one write to \(uuid)")
        }
    }

    static func checkSubscribe(_ properties: CBCharacteristicProperties, of uuid: String) throws {
        guard properties.contains(.notify) || properties.contains(.indicate) else {
            throw BLEError.subscribeFailed("characteristic \(uuid) neither notifies nor indicates (\(describe(properties)))")
        }
    }

    /// The property names `info` and `char` show, in that order.
    static func propertyNames(_ properties: CBCharacteristicProperties) -> [String] {
        var list: [String] = []
        if properties.contains(.read) { list.append("read") }
        if properties.contains(.write) { list.append("write") }
        if properties.contains(.writeWithoutResponse) { list.append("writeNoResp") }
        if properties.contains(.notify) { list.append("notify") }
        if properties.contains(.indicate) { list.append("indicate") }
        if properties.contains(.broadcast) { list.append("broadcast") }
        if properties.contains(.authenticatedSignedWrites) { list.append("signedWrite") }
        if properties.contains(.extendedProperties) { list.append("extended") }
        return list
    }

    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        let names = propertyNames(properties)
        return "properties: " + (names.isEmpty ? "none" : names.joined(separator: ", "))
    }
}
