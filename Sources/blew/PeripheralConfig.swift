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

    /// Load from a JSON file at `path`.
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
        } catch let decodingError {
            throw ConfigError.invalidJSON(decodingError.localizedDescription)
        }
    }

    /// Resolve initial Data values from each characteristic's `value` + `format` fields.
    /// Returns a dictionary keyed by characteristic UUID (uppercased).
    func resolvedInitialValues() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for svc in services {
            for char in svc.characteristics {
                guard let valueStr = char.value else { continue }
                let fmt = char.format ?? "hex"
                guard let data = DataFormatter.parse(valueStr, as: fmt) else {
                    throw ConfigError.invalidValue(uuid: char.uuid, value: valueStr, format: fmt)
                }
                result[char.uuid.uppercased()] = data
            }
        }
        return result
    }

    enum ConfigError: Error, LocalizedError {
        case fileNotFound(String)
        case invalidJSON(String)
        case invalidValue(uuid: String, value: String, format: String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path):
                return "Config file not found: \(path)"
            case .invalidJSON(let msg):
                return "Invalid JSON in config: \(msg)"
            case .invalidValue(let uuid, let value, let fmt):
                return "Cannot parse value '\(value)' as '\(fmt)' for characteristic \(uuid)"
            }
        }
    }
}
