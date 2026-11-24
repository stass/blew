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
    case notificationsDropped(NotificationDrops)
    case peripheralSummary(PeriphSummaryResult)
    case peripheralEvent(PeriphEventRecord)
    case subscriptionList([String])
    case nusData(NUSData)
    case nusStatus(NUSStatus)
    case nusDropped(NUSDrops)
    case message(String)
    case empty
}

// MARK: - Shared types

struct LabeledValue: Codable {
    let label: String
    let value: String
}

extension LabeledValue {
    /// A characteristic value on one line: `value` when there is one,
    /// otherwise the decoded fields as `label: value` joined by ` | `.
    /// Nil when the characteristic was not read.
    static func flattened(value: String?, fields: [LabeledValue]?) -> String? {
        if let value { return value }
        guard let fields, !fields.isEmpty else { return nil }
        return fields.map { $0.label.isEmpty ? $0.value : "\($0.label): \($0.value)" }
            .joined(separator: " | ")
    }
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
    let format: ValueFormat
}

struct NotificationValue: Codable {
    let timestamp: String
    let char: String
    let name: String?
    let value: String
}

/// Notifications of `char` that a subscription dropped because they came
/// faster than blew wrote them out: `total` so far in that subscription.
struct NotificationDrops: Codable, Equatable {
    let char: String
    let total: Int

    /// The status line, without the command or characteristic in front.
    var text: String {
        "\(total) notifications of \(char) dropped: they came faster than they were written out"
    }
}

/// Bytes received from a device's Nordic UART Service TX characteristic.
struct NUSData: Codable {
    let timestamp: String
    let data: Data
}

/// A `nus` bridge event: `bridge` (the local endpoint), `connected`,
/// `client` (a TCP client came or went), `disconnected`, `reconnecting`.
struct NUSStatus: Codable, Equatable {
    let event: String
    let detail: String
}

/// Notifications from a NUS device that the bridge dropped because they
/// came faster than it passed them on (`NotificationStream.capacity`):
/// `session` since this connection's session started, `total` since the
/// command started, over every reconnect. Reported at the first loss of a
/// session and, with `sessionEnded`, when a session that lost more since
/// ends.
struct NUSDrops: Codable, Equatable {
    let session: Int
    let total: Int
    let sessionEnded: Bool

    /// The `dropped` event's detail.
    var detail: String {
        sessionEnded
            ? "\(session) notifications from the device in this session"
            : "\(session) notifications from the device: they came faster than blew delivered them"
    }
}

/// What an MCP `ble_nus` call received, all notifications joined.
struct NUSTranscript: Codable, Equatable {
    /// The bytes as UTF-8, invalid sequences replaced.
    let received: String
    let receivedHex: String
    /// The notifications dropped before blew collected them, so missing
    /// from `received`; 0 when none were.
    let dropped: Int
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
