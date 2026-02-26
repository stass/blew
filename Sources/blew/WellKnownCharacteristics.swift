import Foundation

// Maps Bluetooth SIG standard characteristic UUIDs to the DataFormatter format string
// that correctly decodes their value. Only characteristics with a single unambiguous
// scalar or string encoding are included. Complex multi-field characteristics (e.g.
// Heart Rate Measurement) are intentionally omitted and fall back to hex.
enum WellKnownCharacteristics {
    // Short UUID (uppercase 4-char hex) → DataFormatter format name.
    private static let formats: [String: String] = [
        // GAP / Generic Access
        "2A00": "utf8",    // Device Name
        "2A01": "uint16le", // Appearance
        "2A04": "hex",     // Peripheral Preferred Connection Parameters

        // Device Information Service
        "2A23": "hex",     // System ID
        "2A24": "utf8",    // Model Number String
        "2A25": "utf8",    // Serial Number String
        "2A26": "utf8",    // Firmware Revision String
        "2A27": "utf8",    // Hardware Revision String
        "2A28": "utf8",    // Software Revision String
        "2A29": "utf8",    // Manufacturer Name String
        "2A50": "hex",     // PnP ID

        // Battery Service
        "2A19": "uint8",   // Battery Level

        // Current Time Service
        "2A2B": "hex",     // Current Time
        "2A0F": "hex",     // Local Time Information

        // Environmental Sensing
        "2A6E": "uint16le", // Temperature (0.01 °C units)
        "2A6F": "uint16le", // Humidity (0.01 % units)
        "2A6D": "uint32le", // Pressure (0.1 Pa units)

        // Heart Rate Service
        "2A37": "hex",     // Heart Rate Measurement (multi-field)
        "2A38": "uint8",   // Body Sensor Location

        // Health Thermometer
        "2A1C": "hex",     // Temperature Measurement (multi-field)
        "2A1D": "uint8",   // Temperature Type

        // Alert Notification
        "2A46": "hex",     // New Alert
        "2A45": "hex",     // Unread Alert Status

        // Glucose
        "2A18": "hex",     // Glucose Measurement (multi-field)

        // TX Power
        "2A07": "uint8",   // Tx Power Level (signed, but uint8 for raw display)
    ]

    /// Returns the DataFormatter format string for the given UUID, or "hex" if not known.
    static func bestFormat(for uuid: String) -> String {
        guard let short = BLENames.shortUUID(uuid) else { return "hex" }
        return formats[short] ?? "hex"
    }

    /// Decodes data using the known format for the UUID, returning nil if the UUID
    /// has no entry in the format table (i.e. the caller should use hex or skip).
    static func decode(_ data: Data, uuid: String) -> String? {
        guard let short = BLENames.shortUUID(uuid), formats[short] != nil else { return nil }
        return DataFormatter.format(data, as: bestFormat(for: uuid))
    }
}
