import Foundation
import BLEManager

/// Top-level structure for a peripheral config JSON file.
///
/// Example:
/// ```json
/// {
///   "name": "My Device",
///   "services": [
///     {
///       "uuid": "180F",
///       "primary": true,
///       "characteristics": [
///         {
///           "uuid": "2A19",
///           "properties": ["read", "notify"],
///           "value": "55",
///           "format": "uint8"
///         }
///       ]
///     }
///   ]
/// }
/// ```
struct PeripheralConfig: Codable {
    let name: String?
    let services: [ServiceDefinition]

    init(name: String?, services: [ServiceDefinition]) {
        self.name = name
        self.services = services
    }

    private enum CodingKeys: String, CodingKey { case name, services }

    /// Rejects a characteristic UUID that appears twice, in any spelling: the
    /// GATT server keys values, subscribers and registrations by UUID alone.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        services = try container.decode([ServiceDefinition].self, forKey: .services)
        var seen: [BLEUUID: String] = [:]
        for (s, service) in services.enumerated() {
            for (c, char) in service.characteristics.enumerated() {
                let location = "services[\(s)].characteristics[\(c)]"
                if let first = seen[char.uuid] {
                    throw DecodingError.dataCorruptedError(
                        forKey: .services, in: container,
                        debugDescription: "characteristic \(char.uuid) at \(location) "
                            + "is the same UUID as \(first); characteristic UUIDs must be unique")
                }
                seen[char.uuid] = location
            }
        }
    }

    /// Load from a JSON file at `path`.
    ///
    /// Decoding validates every UUID (`BLEUUID`) and rejects descriptors
    /// (`CharacteristicDefinition`), so a loaded config never reaches a
    /// CoreBluetooth call that raises.
    static func load(from path: String) throws -> PeripheralConfig {
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.fileNotFound(path)
        }
        do {
            return try JSONDecoder().decode(PeripheralConfig.self, from: data)
        } catch let error as DecodingError {
            throw ConfigError.invalidConfig(describe(error))
        }
    }

    /// Resolve initial Data values from each characteristic's `value` + `format` fields.
    func resolvedInitialValues() throws -> [BLEUUID: Data] {
        var result: [BLEUUID: Data] = [:]
        for svc in services {
            for char in svc.characteristics {
                guard let valueStr = char.value else { continue }
                let fmt = char.format ?? "hex"
                guard let data = DataFormatter.parse(valueStr, as: fmt) else {
                    throw ConfigError.invalidValue(uuid: char.uuid.string, value: valueStr, format: fmt)
                }
                result[char.uuid] = data
            }
        }
        return result
    }

    /// "services[0].characteristics[1].uuid: <what is wrong>"
    static func describe(_ error: DecodingError) -> String {
        let path: [CodingKey]
        var detail: String
        switch error {
        case .dataCorrupted(let context):
            path = context.codingPath
            detail = context.debugDescription
            if let underlying = context.underlyingError as NSError?,
               let reason = underlying.userInfo["NSDebugDescription"] as? String {
                detail += " \(reason)"
            }
        case .keyNotFound(let key, let context):
            path = context.codingPath
            detail = "missing key \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            path = context.codingPath
            detail = context.debugDescription
        @unknown default:
            return error.localizedDescription
        }
        let location = path.enumerated().map { i, key in
            if let index = key.intValue { return "[\(index)]" }
            return i == 0 ? key.stringValue : ".\(key.stringValue)"
        }.joined()
        return location.isEmpty ? detail : "\(location): \(detail)"
    }

    enum ConfigError: Error, LocalizedError {
        case fileNotFound(String)
        case invalidConfig(String)
        case invalidValue(uuid: String, value: String, format: String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path):
                return "Config file not found: \(path)"
            case .invalidConfig(let msg):
                return "Invalid config: \(msg)"
            case .invalidValue(let uuid, let value, let fmt):
                return "Cannot parse value '\(value)' as '\(fmt)' for characteristic \(uuid)"
            }
        }
    }
}
