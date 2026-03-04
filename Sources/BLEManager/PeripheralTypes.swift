import Foundation

/// Defines a GATT service to be hosted by the peripheral.
public struct ServiceDefinition: Sendable, Codable {
    public let uuid: String
    public let primary: Bool
    public let characteristics: [CharacteristicDefinition]

    public init(uuid: String, primary: Bool = true, characteristics: [CharacteristicDefinition]) {
        self.uuid = uuid
        self.primary = primary
        self.characteristics = characteristics
    }
}

/// Defines a GATT characteristic within a service definition.
public struct CharacteristicDefinition: Sendable, Codable {
    public let uuid: String
    public let properties: [CharacteristicProperty]
    /// Initial value string, interpreted according to `format`.
    public let value: String?
    /// DataFormatter format name for `value`. Defaults to "hex" when nil.
    public let format: String?
    /// Descriptor UUIDs to add to this characteristic.
    public let descriptors: [String]?

    public init(
        uuid: String,
        properties: [CharacteristicProperty],
        value: String? = nil,
        format: String? = nil,
        descriptors: [String]? = nil
    ) {
        self.uuid = uuid
        self.properties = properties
        self.value = value
        self.format = format
        self.descriptors = descriptors
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
