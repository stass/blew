import Foundation
import CoreBluetooth

public struct DiscoveredDevice: Sendable {
    public let identifier: String
    public let name: String?
    public let rssi: Int
    public let serviceUUIDs: [String]
    public let manufacturerData: Data?

    public init(
        identifier: String,
        name: String?,
        rssi: Int,
        serviceUUIDs: [String],
        manufacturerData: Data?
    ) {
        self.identifier = identifier
        self.name = name
        self.rssi = rssi
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerData = manufacturerData
    }
}

public struct ServiceInfo: Sendable {
    public let uuid: String
    public let isPrimary: Bool

    public init(uuid: String, isPrimary: Bool) {
        self.uuid = uuid
        self.isPrimary = isPrimary
    }
}

public struct CharacteristicInfo: Sendable {
    public let uuid: String
    public let properties: [String]
    public let descriptors: [DescriptorInfo]

    public init(uuid: String, properties: [String], descriptors: [DescriptorInfo] = []) {
        self.uuid = uuid
        self.properties = properties
        self.descriptors = descriptors
    }
}

public struct DescriptorInfo: Sendable {
    public let uuid: String

    public init(uuid: String) {
        self.uuid = uuid
    }
}

public struct ServiceTree: Sendable {
    public let uuid: String
    public let isPrimary: Bool
    public let characteristics: [CharacteristicInfo]

    public init(uuid: String, isPrimary: Bool, characteristics: [CharacteristicInfo]) {
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.characteristics = characteristics
    }
}

public struct ConnectionStatus: Sendable, Codable {
    public let isConnected: Bool
    public let deviceId: String?
    public let deviceName: String?
    public let servicesCount: Int
    public let characteristicsCount: Int
    public let subscriptionsCount: Int
    public let lastError: String?

    public init(
        isConnected: Bool,
        deviceId: String? = nil,
        deviceName: String? = nil,
        servicesCount: Int = 0,
        characteristicsCount: Int = 0,
        subscriptionsCount: Int = 0,
        lastError: String? = nil
    ) {
        self.isConnected = isConnected
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.servicesCount = servicesCount
        self.characteristicsCount = characteristicsCount
        self.subscriptionsCount = subscriptionsCount
        self.lastError = lastError
    }
}

public enum WriteType: Sendable {
    case withResponse
    case withoutResponse
    case auto
}
