import Foundation

/// Defines a GATT service to be hosted by the peripheral.
public struct ServiceDefinition: Sendable, Codable {
    public let uuid: BLEUUID
    public let primary: Bool
    public let characteristics: [CharacteristicDefinition]

    public init(uuid: BLEUUID, primary: Bool = true, characteristics: [CharacteristicDefinition]) {
        self.uuid = uuid
        self.primary = primary
        self.characteristics = characteristics
    }
}

/// Defines a GATT characteristic within a service definition.
///
/// A config file may not list descriptors. CoreBluetooth creates 2900 and
/// 2902 itself from the characteristic's properties, hosts no other
/// descriptor except 2901 and 2904, and raises an Objective-C exception for
/// those two without a value, which the config format does not carry.
/// Decoding therefore rejects a `descriptors` key that lists any.
public struct CharacteristicDefinition: Sendable, Codable {
    public let uuid: BLEUUID
    public let properties: [CharacteristicProperty]
    /// Initial value string, interpreted according to `format`.
    public let value: String?
    /// DataFormatter format name for `value`. Defaults to "hex" when nil.
    public let format: String?

    public init(
        uuid: BLEUUID,
        properties: [CharacteristicProperty],
        value: String? = nil,
        format: String? = nil
    ) {
        self.uuid = uuid
        self.properties = properties
        self.value = value
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, properties, value, format, descriptors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(BLEUUID.self, forKey: .uuid)
        properties = try container.decode([CharacteristicProperty].self, forKey: .properties)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        if let descriptor = try container.decodeIfPresent([BLEUUID].self, forKey: .descriptors)?.first {
            throw DecodingError.dataCorruptedError(
                forKey: .descriptors, in: container,
                debugDescription: Self.rejection(of: descriptor))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(properties, forKey: .properties)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(format, forKey: .format)
    }

    private static func rejection(of descriptor: BLEUUID) -> String {
        switch descriptor.key {
        case "2900", "2902":
            return "descriptor \(descriptor) cannot be configured: CoreBluetooth creates it "
                + "itself from the characteristic's properties"
        case "2901", "2904":
            return "descriptor \(descriptor) needs a value, and the config format has no "
                + "descriptor values"
        default:
            return "descriptor \(descriptor) is not supported: CoreBluetooth hosts only "
                + "descriptors 2901 and 2904"
        }
    }
}

/// Characteristic property flags expressible in config files and API calls.
public enum CharacteristicProperty: String, Sendable, Codable, CaseIterable {
    case read
    case write
    case writeWithoutResponse
    case notify
    case indicate
}

/// Snapshot of the peripheral's advertising/GATT state.
public struct PeripheralStatus: Sendable, Codable {
    public let isAdvertising: Bool
    public let advertisedName: String?
    public let serviceCount: Int
    public let characteristicCount: Int
    public let subscriberCount: Int

    public init(
        isAdvertising: Bool,
        advertisedName: String?,
        serviceCount: Int,
        characteristicCount: Int,
        subscriberCount: Int
    ) {
        self.isAdvertising = isAdvertising
        self.advertisedName = advertisedName
        self.serviceCount = serviceCount
        self.characteristicCount = characteristicCount
        self.subscriberCount = subscriberCount
    }
}
