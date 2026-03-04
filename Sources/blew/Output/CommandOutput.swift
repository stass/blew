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

// MARK: - Shared types

struct LabeledValue: Codable {
    let label: String
    let value: String
}

// MARK: - Row types

struct DeviceRow: Codable {
    let id: String
    let name: String?
    let rssi: Int
    let serviceUUIDs: [String]
    let serviceDisplayNames: [String]
}

struct ServiceRow: Codable {
    let uuid: String
    let name: String?
    let isPrimary: Bool
}

struct CharacteristicRow: Codable {
    let uuid: String
    let name: String?
    let properties: [String]
    let value: String?
    let valueFields: [LabeledValue]?
}

struct DescriptorRow: Codable {
    let uuid: String
    let name: String?
}

// MARK: - GATT tree types

struct GATTTreeService: Codable {
    let uuid: String
    let name: String?
    let characteristics: [GATTTreeCharacteristic]
}

struct GATTTreeCharacteristic: Codable {
    let uuid: String
    let name: String?
    let properties: [String]
    let value: String?
    let valueFields: [LabeledValue]?
    let descriptors: [DescriptorRow]
}

// MARK: - Info types

struct GATTCharInfo: Codable {
    let uuid: String
    let name: String
    let description: String
    let fields: [GATTDecoder.FieldInfo]
}

// MARK: - Value types

struct ReadResult: Codable {
    let char: String
    let name: String?
    let value: String
    let format: String
}

struct NotificationValue: Codable {
    let timestamp: String
    let char: String
    let name: String?
    let value: String
}

// MARK: - Peripheral types

struct PeriphSummaryResult: Codable {
    let name: String
    let serviceUUIDs: [String]
    let services: [ServiceDefinition]
}

struct PeriphEventRecord: Codable {
    let timestamp: String
    let event: PeripheralEvent
}
