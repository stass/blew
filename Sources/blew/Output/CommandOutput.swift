import Foundation
import BLEManager

struct CommandResult {
    var exitCode: Int32 = 0
    var output: [CommandOutput] = []
    var errors: [String] = []
    var infos: [String] = []
    var debugs: [String] = []
}

enum CommandOutput {
    case devices([DeviceRow])
    case services([ServiceRow])
    case characteristics([CharacteristicRow])
    case descriptors([DescriptorRow])
    case gattTree([GATTTreeService])
    case characteristicInfo(GATTCharInfo)
    case connectionStatus(ConnectionStatus)
    case peripheralStatus(PeripheralStatus)
    case readValue(ReadResult)
    case writeSuccess(char: String, name: String?)
    case notification(NotificationValue)
    case peripheralSummary(PeriphSummaryResult)
    case peripheralEvent(PeriphEventRecord)
    case subscriptionList([String])
    case message(String)
    case empty
}

// MARK: - Row types

struct DeviceRow {
    let id: String
    let name: String?
    let rssi: Int
    let serviceUUIDs: [String]
    let serviceDisplayNames: [String]
}

struct ServiceRow {
    let uuid: String
    let name: String?
    let isPrimary: Bool
}

struct CharacteristicRow {
    let uuid: String
    let name: String?
    let properties: [String]
    let value: String?
    let valueFields: [(label: String, value: String)]?
}

struct DescriptorRow {
    let uuid: String
    let name: String?
}

// MARK: - GATT tree types

struct GATTTreeService {
    let uuid: String
    let name: String?
    let characteristics: [GATTTreeCharacteristic]
}

struct GATTTreeCharacteristic {
    let uuid: String
    let name: String?
    let properties: [String]
    let value: String?
    let valueFields: [(label: String, value: String)]?
    let descriptors: [DescriptorRow]
}

// MARK: - Info types

struct GATTCharInfo {
    let uuid: String
    let name: String
    let description: String
    let fields: [GATTDecoder.FieldInfo]
}

// MARK: - Value types

struct ReadResult {
    let char: String
    let name: String?
    let value: String
    let format: String
}

struct NotificationValue {
    let timestamp: String
    let char: String
    let name: String?
    let value: String
}

// MARK: - Peripheral types

struct PeriphSummaryResult {
    let name: String
    let serviceUUIDs: [String]
    let services: [ServiceDefinition]
}

struct PeriphEventRecord {
    let timestamp: String
    let event: PeripheralEvent
}
