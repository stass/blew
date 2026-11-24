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
                conditionDescription: conditionDescription(f.conditions)
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
        /// "present if ..." for a conditional field, nil for one always present.
        let conditionDescription: String?
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
        // The unsigned value of each decoded integer field, by name, for the
        // presence conditions of the fields after it.
        var integers: [String: UInt64] = [:]
        var result: [DecodedField] = []

        for field in fields {
            guard field.conditions.allSatisfy({ holds($0, integers) }) else { continue }

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
                if let value = unsignedValue(fieldData, type: field.type) {
                    integers[field.name] = value
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

    /// Whether `condition` holds, given the integer fields decoded so far. A
    /// condition on a field that was not decoded does not hold.
    private static func holds(
        _ condition: GATTCharacteristicDB.Condition,
        _ integers: [String: UInt64]
    ) -> Bool {
        switch condition {
        case .bit(let field, let bit, let set):
            guard let value = integers[field] else { return false }
            return (value >> UInt64(bit)) & 1 == (set ? 1 : 0)
        case .equals(let field, let value):
            return integers[field] == value
        case .notEquals(let field, let value):
            guard let actual = integers[field] else { return false }
            return actual != value
        case .external:
            return true
        }
    }

    /// The little-endian unsigned value of an unsigned-integer or bit-field
    /// field; nil for every other type.
    private static func unsignedValue(_ data: Data, type: GATTCharacteristicDB.FieldType) -> UInt64? {
        switch type {
        case .uint8, .uint16, .uint24, .uint32, .uint48, .uint64,
             .boolean8, .boolean16, .boolean24, .boolean32:
            guard data.count <= 8 else { return nil }
            return littleEndian(data)
        default:
            return nil
        }
    }

    /// The little-endian unsigned value of up to 8 bytes.
    private static func littleEndian(_ data: Data) -> UInt64 {
        data.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func conditionDescription(_ conditions: [GATTCharacteristicDB.Condition]) -> String? {
        guard !conditions.isEmpty else { return nil }
        let parts = conditions.map { condition -> String in
            switch condition {
            case .bit(let field, let bit, let set): return "bit \(bit) of \(field) is \(set ? 1 : 0)"
            case .equals(let field, let value):     return "\(field) is \(value)"
            case .notEquals(let field, let value):  return "\(field) is not \(value)"
            case .external(let text):               return text
            }
        }
        return "present if " + parts.joined(separator: " and ")
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
            return "\(data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })"

        case .uint24:
            guard data.count >= 3 else { return "(short)" }
            let lo = UInt32(data[data.startIndex])
            let mid = UInt32(data[data.index(data.startIndex, offsetBy: 1)])
            let hi = UInt32(data[data.index(data.startIndex, offsetBy: 2)])
            return "\(lo | (mid << 8) | (hi << 16))"

        case .uint32:
            guard data.count >= 4 else { return "(short)" }
            return "\(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })"

        case .uint48:
            guard data.count >= 6 else { return "(short)" }
            var value: UInt64 = 0
            for i in 0..<6 {
                value |= UInt64(data[data.index(data.startIndex, offsetBy: i)]) << (i * 8)
            }
            return "\(value)"

        case .uint64:
            guard data.count >= 8 else { return "(short)" }
            return "\(data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })"

        case .sint8:
            guard data.count >= 1 else { return "(short)" }
            return "\(Int8(bitPattern: data[data.startIndex]))"

        case .sint16:
            guard data.count >= 2 else { return "(short)" }
            return "\(data.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })"

        case .sint32:
            guard data.count >= 4 else { return "(short)" }
            return "\(data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })"

        case .boolean8:
            guard data.count >= 1 else { return "(short)" }
            return String(format: "0x%02X", data[data.startIndex])

        case .boolean16:
            guard data.count >= 2 else { return "(short)" }
            return String(format: "0x%04X", data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })

        case .boolean24:
            guard data.count >= 3 else { return "(short)" }
            return String(format: "0x%06X", UInt32(littleEndian(data.prefix(3))))

        case .boolean32:
            guard data.count >= 4 else { return "(short)" }
            return String(format: "0x%08X", data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })

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

    // IEEE 11073-20601 SFLOAT-16: 4-bit signed exponent, 12-bit signed
    // mantissa. The special values are the mantissas 0x07FE to 0x0802 with
    // exponent 0 (IEEE 11073-20601 is not vendored; the values are from its
    // SFLOAT-Type definition). With any other exponent they are numbers.
    static func decodeMedfloat16(_ data: Data) -> String {
        guard data.count >= 2 else { return "(short)" }
        let raw = data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        let expRaw = Int(raw >> 12)
        let exp = expRaw > 7 ? expRaw - 16 : expRaw
        let mantRaw = Int(raw & 0x0FFF)
        let mant = mantRaw > 0x07FF ? mantRaw - 0x1000 : mantRaw
        switch (exp, mantRaw) {
        case (0, 0x07FF): return "NaN"
        case (0, 0x0800): return "NRes"
        case (0, 0x07FE): return "+Inf"
        case (0, 0x0802): return "-Inf"
        case (0, 0x0801): return "Reserved"
        default:
            let value = Double(mant) * pow(10.0, Double(exp))
            return value == value.rounded() && abs(value) < 1e9
                ? String(format: "%.0f", value)
                : String(format: "%.6g", value)
        }
    }

    // IEEE 11073-20601 FLOAT-32: 8-bit signed exponent, 24-bit signed
    // mantissa. The special values are the mantissas 0x007FFFFE to
    // 0x00800002 with exponent 0, as for SFLOAT.
    static func decodeMedfloat32(_ data: Data) -> String {
        guard data.count >= 4 else { return "(short)" }
        let raw = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let exp = Int(Int8(bitPattern: UInt8(raw >> 24)))
        let mantRaw = Int(raw & 0x00FFFFFF)
        let mant = mantRaw > 0x007FFFFF ? mantRaw - 0x01000000 : mantRaw
        switch (exp, mantRaw) {
        case (0, 0x007FFFFF): return "NaN"
        case (0, 0x00800000): return "NRes"
        case (0, 0x007FFFFE): return "+Inf"
        case (0, 0x00800002): return "-Inf"
        case (0, 0x00800001): return "Reserved"
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
        case .boolean24:  return "boolean[24]"
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
