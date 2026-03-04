import Foundation

// Decodes characteristic values using the auto-generated GATTCharacteristicDB.
// Replaces the hand-maintained WellKnownCharacteristics table.
enum GATTDecoder {

    // MARK: - Public API

    /// Decodes a characteristic value into a human-readable string using the
    /// generated GSS database. Returns nil when the UUID is not in the database
    /// (caller should fall back to hex).
    static func decode(_ data: Data, uuid: String) -> String? {
        guard let short = BLENames.shortUUID(uuid),
              let char = GATTCharacteristicDB.db[short],
              !char.fields.isEmpty else { return nil }

        let parts = parseFields(char.fields, from: data)
        guard !parts.isEmpty else { return nil }

        if parts.count == 1 {
            return parts[0].value
        }
        return parts.map { "\($0.name): \($0.value)" }.joined(separator: " | ")
    }

    /// Returns structured info about a characteristic for the `gatt info` command.
    /// Returns nil when the UUID is not in the database.
    static func info(for uuid: String) -> CharacteristicInfo? {
        guard let short = BLENames.shortUUID(uuid),
              let char = GATTCharacteristicDB.db[short] else { return nil }

        let fieldInfos = char.fields.map { f in
            FieldInfo(
                name: f.name,
                typeName: typeName(f.type),
                sizeDescription: sizeDescription(f.size),
                flagBit: f.flagBit,
                flagSet: f.flagSet
            )
        }
        return CharacteristicInfo(
            uuid: short,
            name: char.name,
            description: char.description,
            fields: fieldInfos
        )
    }

    // MARK: - Info types

    struct FieldInfo: Codable {
        let name: String
        let typeName: String
        let sizeDescription: String
        let flagBit: Int
        let flagSet: Bool

        var conditionDescription: String? {
            guard flagBit >= 0 else { return nil }
            return "present if bit \(flagBit) of Flags is \(flagSet ? "1" : "0")"
        }
    }

    struct CharacteristicInfo {
        let uuid: String
        let name: String
        let description: String
        let fields: [FieldInfo]
    }

    // MARK: - Field parsing

    private struct DecodedField {
        let name: String
        let value: String
    }

    private static func parseFields(
        _ fields: [GATTCharacteristicDB.Field],
        from data: Data
    ) -> [DecodedField] {
        var offset = data.startIndex
        var flags: UInt64 = 0
        var flagsCaptured = false
        var result: [DecodedField] = []

        for field in fields {
            // Conditional field: check flag bit
            if field.flagBit >= 0 {
                let bitSet = (flags >> UInt64(field.flagBit)) & 1 == 1
                guard bitSet == field.flagSet else { continue }
            }

            let remaining = data.distance(from: offset, to: data.endIndex)

            if field.size == -1 || field.size == -2 {
                // Variable-length: consume all remaining bytes
                guard remaining > 0 else { continue }
                let fieldData = Data(data[offset...])
                offset = data.endIndex
                result.append(DecodedField(
                    name: field.name,
                    value: formatValue(fieldData, type: field.type)
                ))
            } else {
                // Fixed-size
                guard field.size > 0, remaining >= field.size else { continue }
                let endOffset = data.index(offset, offsetBy: field.size)
                let fieldData = Data(data[offset..<endOffset])

                // Capture flags from the first boolean field for conditional resolution
                if !flagsCaptured {
                    switch field.type {
                    case .boolean8:
                        flags = UInt64(fieldData[fieldData.startIndex])
                        flagsCaptured = true
                    case .boolean16:
                        flags = fieldData.withUnsafeBytes { UInt64($0.load(as: UInt16.self)) }
                        flagsCaptured = true
                    case .boolean32:
                        flags = fieldData.withUnsafeBytes { UInt64($0.load(as: UInt32.self)) }
                        flagsCaptured = true
                    default:
                        break
                    }
                }

                offset = endOffset
                result.append(DecodedField(
                    name: field.name,
                    value: formatValue(fieldData, type: field.type)
                ))
            }
        }

        return result
    }

    // MARK: - Value formatting

    private static func formatValue(
        _ data: Data,
        type: GATTCharacteristicDB.FieldType
    ) -> String {
        switch type {
        case .uint8:
            guard data.count >= 1 else { return "(short)" }
            return "\(data[data.startIndex])"

        case .uint16:
            guard data.count >= 2 else { return "(short)" }
            return "\(data.withUnsafeBytes { $0.load(as: UInt16.self) })"

        case .uint24:
            guard data.count >= 3 else { return "(short)" }
            let lo = UInt32(data[data.startIndex])
            let mid = UInt32(data[data.index(data.startIndex, offsetBy: 1)])
            let hi = UInt32(data[data.index(data.startIndex, offsetBy: 2)])
            return "\(lo | (mid << 8) | (hi << 16))"

        case .uint32:
            guard data.count >= 4 else { return "(short)" }
            return "\(data.withUnsafeBytes { $0.load(as: UInt32.self) })"

        case .uint48:
            guard data.count >= 6 else { return "(short)" }
            var value: UInt64 = 0
            for i in 0..<6 {
                value |= UInt64(data[data.index(data.startIndex, offsetBy: i)]) << (i * 8)
            }
            return "\(value)"

        case .uint64:
            guard data.count >= 8 else { return "(short)" }
            return "\(data.withUnsafeBytes { $0.load(as: UInt64.self) })"

        case .sint8:
            guard data.count >= 1 else { return "(short)" }
            return "\(Int8(bitPattern: data[data.startIndex]))"

        case .sint16:
            guard data.count >= 2 else { return "(short)" }
            return "\(data.withUnsafeBytes { $0.load(as: Int16.self) })"

        case .sint32:
            guard data.count >= 4 else { return "(short)" }
            return "\(data.withUnsafeBytes { $0.load(as: Int32.self) })"

        case .boolean8:
            guard data.count >= 1 else { return "(short)" }
            return String(format: "0x%02X", data[data.startIndex])

        case .boolean16:
            guard data.count >= 2 else { return "(short)" }
            return String(format: "0x%04X", data.withUnsafeBytes { $0.load(as: UInt16.self) })

        case .boolean32:
            guard data.count >= 4 else { return "(short)" }
            return String(format: "0x%08X", data.withUnsafeBytes { $0.load(as: UInt32.self) })

        case .medfloat16:
            return decodeMedfloat16(data)

        case .medfloat32:
            return decodeMedfloat32(data)

        case .utf8s:
            return String(data: data, encoding: .utf8)
                ?? data.map { String(format: "%02x", $0) }.joined()

        case .opaque:
            return data.map { String(format: "%02x", $0) }.joined()
        }
    }

    // IEEE 11073-20601 SFLOAT-16: 4-bit signed exponent, 12-bit signed mantissa
    private static func decodeMedfloat16(_ data: Data) -> String {
        guard data.count >= 2 else { return "(short)" }
        let raw = data.withUnsafeBytes { $0.load(as: UInt16.self) }
        let expRaw = Int(raw >> 12)
        let exp = expRaw > 7 ? expRaw - 16 : expRaw
        let mantRaw = Int(raw & 0x0FFF)
        let mant = mantRaw > 0x07FF ? mantRaw - 0x1000 : mantRaw
        switch mant {
        case 0x07FF:  return "NaN"
        case -0x0800: return "NRes"
        case 0x07FE:  return "+Inf"
        case -0x07FE: return "-Inf"
        default:
            let value = Double(mant) * pow(10.0, Double(exp))
            return value == value.rounded() && abs(value) < 1e9
                ? String(format: "%.0f", value)
                : String(format: "%.6g", value)
        }
    }

    // IEEE 11073-20601 FLOAT-32: 8-bit signed exponent, 24-bit signed mantissa
    private static func decodeMedfloat32(_ data: Data) -> String {
        guard data.count >= 4 else { return "(short)" }
        let raw = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        let exp = Int(Int8(bitPattern: UInt8(raw >> 24)))
        let mantRaw = Int(raw & 0x00FFFFFF)
        let mant = mantRaw > 0x007FFFFF ? mantRaw - 0x01000000 : mantRaw
        switch mant {
        case 0x007FFFFF:  return "NaN"
        case -0x00800000: return "NRes"
        case 0x007FFFFE:  return "+Inf"
        case -0x007FFFFE: return "-Inf"
        default:
            let value = Double(mant) * pow(10.0, Double(exp))
            return value == value.rounded() && abs(value) < 1e12
                ? String(format: "%.0f", value)
                : String(format: "%.9g", value)
        }
    }

    // MARK: - Info helpers

    private static func typeName(_ type: GATTCharacteristicDB.FieldType) -> String {
        switch type {
        case .uint8:      return "uint8"
        case .uint16:     return "uint16"
        case .uint24:     return "uint24"
        case .uint32:     return "uint32"
        case .uint48:     return "uint48"
        case .uint64:     return "uint64"
        case .sint8:      return "sint8"
        case .sint16:     return "sint16"
        case .sint32:     return "sint32"
        case .boolean8:   return "boolean[8]"
        case .boolean16:  return "boolean[16]"
        case .boolean32:  return "boolean[32]"
        case .medfloat16: return "medfloat16"
        case .medfloat32: return "medfloat32"
        case .utf8s:      return "utf8"
        case .opaque:     return "opaque"
        }
    }

    private static func sizeDescription(_ size: Int) -> String {
        switch size {
        case -2:         return "variable (array)"
        case -1:         return "variable"
        case 1:          return "1 byte"
        default:         return "\(size) bytes"
        }
    }
}
