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

struct LabeledValue: Codable, Equatable {
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
    /// What the advertised manufacturer data says; nil when the device
    /// advertises none.
    var manufacturer: AdvertisedManufacturer? = nil
}

/// The JSON form of a device: `manufacturer` becomes `manufacturerID` (a
/// number) and `manufacturer` (the company name) for an identifier, or
/// `manufacturerDataLength` for data too short to hold one; a field with
/// nothing to show is left out.
extension DeviceRow {
    private enum CodingKeys: String, CodingKey {
        case id, name, rssi, serviceUUIDs, serviceDisplayNames
        case manufacturerID, manufacturer, manufacturerDataLength
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        rssi = try c.decode(Int.self, forKey: .rssi)
        serviceUUIDs = try c.decode([String].self, forKey: .serviceUUIDs)
        serviceDisplayNames = try c.decode([String].self, forKey: .serviceDisplayNames)
        if let id = try c.decodeIfPresent(UInt16.self, forKey: .manufacturerID) {
            manufacturer = .company(CompanyIdentifier(id))
        } else if let count = try c.decodeIfPresent(Int.self, forKey: .manufacturerDataLength) {
            manufacturer = .tooShort(byteCount: count)
        } else {
            manufacturer = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(rssi, forKey: .rssi)
        try c.encode(serviceUUIDs, forKey: .serviceUUIDs)
        try c.encode(serviceDisplayNames, forKey: .serviceDisplayNames)
        switch manufacturer {
        case .company(let company)?:
            try c.encode(company.value, forKey: .manufacturerID)
            try c.encodeIfPresent(company.name, forKey: .manufacturer)
        case .tooShort(let count)?:
            try c.encode(count, forKey: .manufacturerDataLength)
        case nil:
            break
        }
    }
}

struct ServiceRow: Codable {
    let uuid: String
    let name: String?
    let isPrimary: Bool
}

/// The value `gatt chars|tree -r` shows for one characteristic: its value
/// on one line, its decoded fields, or why it has none (the read failed,
/// or its bytes do not fit the `-f` format). A failure is this cell's
/// alone; the listing goes on.
enum ListedValue: Equatable {
    case value(String)
    case fields([LabeledValue])
    case failed(String)

    /// The stored `value`, `valueFields` and `valueError` of a row, of
    /// which at most one is set; nil for all three when `listed` is nil (the
    /// characteristic was not read).
    static func columns(_ listed: ListedValue?) -> (value: String?, fields: [LabeledValue]?, error: String?) {
        switch listed {
        case .value(let value): return (value, nil, nil)
        case .fields(let fields): return (nil, fields, nil)
        case .failed(let message): return (nil, nil, message)
        case nil: return (nil, nil, nil)
        }
    }
}

/// `value`, `valueFields` and `valueError` are the JSON of a `ListedValue`
/// (`ListedValue.columns`): at most one is set.
struct CharacteristicRow: Codable {
    let uuid: String
    let name: String?
    let properties: [String]
    let value: String?
    let valueFields: [LabeledValue]?
    var valueError: String? = nil
}

extension CharacteristicRow {
    init(uuid: String, name: String?, properties: [String], listed: ListedValue?) {
        let columns = ListedValue.columns(listed)
        self.init(uuid: uuid, name: name, properties: properties,
                  value: columns.value, valueFields: columns.fields, valueError: columns.error)
    }
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
    var valueError: String? = nil
    let descriptors: [DescriptorRow]
}

extension GATTTreeCharacteristic {
    init(uuid: String, name: String?, properties: [String], listed: ListedValue?, descriptors: [DescriptorRow]) {
        let columns = ListedValue.columns(listed)
        self.init(uuid: uuid, name: name, properties: properties,
                  value: columns.value, valueFields: columns.fields, valueError: columns.error,
                  descriptors: descriptors)
    }
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
