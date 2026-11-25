import Foundation

// Decodes characteristic values using the auto-generated GATTCharacteristicDB.
// Replaces the hand-maintained WellKnownCharacteristics table.
enum GATTDecoder {

    // MARK: - Public API

    /// One decoded field: its GSS name ("Outer.Inner" for a field of an
    /// embedded structure) and its value, or why its bytes are not a value
    /// of its type (invalid UTF-8 in a `utf8s` field).
    struct Field: Equatable {
        let name: String
        let value: Result<String, ValueFormatMismatch>
    }

    /// The fields of a characteristic value decoded with the generated GSS
    /// database, in order. nil when the UUID is not in the database or no
    /// field is present (the caller shows hex).
    static func fields(_ data: Data, uuid: String) -> [Field]? {
        guard let short = BLENames.shortUUID(uuid),
              let char = GATTCharacteristicDB.db[short],
              !char.fields.isEmpty else { return nil }
        let fields = parseFields(char.fields, from: data)
        return fields.isEmpty ? nil : fields
    }

    /// `fields(_:uuid:)` on one line: a single field's value, or
    /// "Name: value | Name: value". Throws the first field that failed;
    /// nil as for `fields(_:uuid:)`. Listings use `fields(_:uuid:)`, whose
    /// field boundaries device text cannot move.
    static func decode(_ data: Data, uuid: String) throws(ValueFormatMismatch) -> String? {
        guard let fields = fields(data, uuid: uuid) else { return nil }
        var parts: [String] = []
        for field in fields {
            let value = try field.value.get()
            parts.append(fields.count == 1 ? value : "\(field.name): \(value)")
        }
        return parts.joined(separator: " | ")
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
                conditions: f.conditions,
                scale: f.scale,
                unit: f.unit?.id
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

    /// One field of `gatt info`. Its JSON `condition` and
    /// `conditionDescription` both derive from `conditions`, so they cannot
    /// disagree with each other or with the decoder, and `scale` and `unit`
    /// are the decoder's own; README.md's `gatt info` section is the schema.
    struct FieldInfo: Codable {
        let name: String
        let typeName: String
        let sizeDescription: String
        /// The decoder's presence conditions; all must hold, empty means always.
        let conditions: [GATTCharacteristicDB.Condition]
        /// The scale the decoder applies; nil when it shows the raw value.
        let scale: GATTCharacteristicDB.Scale?
        /// The org.bluetooth.unit identifier the decoder names after the value.
        let unit: String?

        /// "present if ..." for a conditional field, nil for one always present.
        var conditionDescription: String? { GATTDecoder.conditionDescription(conditions) }

        init(name: String, typeName: String, sizeDescription: String,
             conditions: [GATTCharacteristicDB.Condition],
             scale: GATTCharacteristicDB.Scale? = nil, unit: String? = nil) {
            self.name = name
            self.typeName = typeName
            self.sizeDescription = sizeDescription
            self.conditions = conditions
            self.scale = scale
            self.unit = unit
        }

        private enum CodingKeys: String, CodingKey {
            case name, typeName, sizeDescription, scale, unit, condition, conditionDescription
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(typeName, forKey: .typeName)
            try container.encode(sizeDescription, forKey: .sizeDescription)
            try container.encodeIfPresent(scale, forKey: .scale)
            try container.encodeIfPresent(unit, forKey: .unit)
            guard let description = conditionDescription else { return }
            if conditions.count == 1 {
                try container.encode(conditions[0], forKey: .condition)
            } else {
                var allOf = container.nestedContainer(keyedBy: ConditionKey.self, forKey: .condition)
                try allOf.encode(ConditionKind.allOf, forKey: .kind)
                try allOf.encode(conditions, forKey: .conditions)
            }
            try container.encode(description, forKey: .conditionDescription)
        }

        /// Reads `condition` back; `conditionDescription` is derived from it,
        /// so its encoded text is not read. Decoding exists because
        /// `StructuredResult` is `Codable`; blew only encodes these values,
        /// so this is not a trust boundary, and its checks only keep a
        /// decoded `.bit` from trapping in `holds`.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            typeName = try container.decode(String.self, forKey: .typeName)
            sizeDescription = try container.decode(String.self, forKey: .sizeDescription)
            scale = try container.decodeIfPresent(GATTCharacteristicDB.Scale.self, forKey: .scale)
            unit = try container.decodeIfPresent(String.self, forKey: .unit)
            guard container.contains(.condition) else {
                conditions = []
                return
            }
            let condition = try container.nestedContainer(keyedBy: ConditionKey.self, forKey: .condition)
            if try condition.decode(ConditionKind.self, forKey: .kind) == .allOf {
                let all = try condition.decode([GATTCharacteristicDB.Condition].self, forKey: .conditions)
                guard all.count >= 2 else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .conditions, in: condition,
                        debugDescription: "allOf needs at least two conditions")
                }
                conditions = all
            } else {
                conditions = [try container.decode(GATTCharacteristicDB.Condition.self, forKey: .condition)]
            }
        }
    }

    struct CharacteristicInfo {
        let uuid: String
        let name: String
        let description: String
        let fields: [FieldInfo]
    }

    // MARK: - Field parsing

    private static func parseFields(
        _ fields: [GATTCharacteristicDB.Field],
        from data: Data
    ) -> [Field] {
        var offset = data.startIndex
        // The unsigned value of each decoded integer field, by name, for the
        // presence conditions of the fields after it.
        var integers: [String: UInt64] = [:]
        var result: [Field] = []

        for field in fields {
            guard field.conditions.allSatisfy({ holds($0, integers) }) else { continue }

            let remaining = data.distance(from: offset, to: data.endIndex)

            if field.size == -1 || field.size == -2 {
                // Variable-length: consume all remaining bytes
                guard remaining > 0 else { continue }
                let fieldData = Data(data[offset...])
                offset = data.endIndex
                result.append(Field(name: field.name, value: fieldValue(fieldData, field: field)))
            } else {
                // Fixed-size
                guard field.size > 0, remaining >= field.size else { continue }
                let endOffset = data.index(offset, offsetBy: field.size)
                let fieldData = Data(data[offset..<endOffset])
                if let value = unsignedValue(fieldData, type: field.type) {
                    integers[field.name] = value
                }
                offset = endOffset
                result.append(Field(name: field.name, value: fieldValue(fieldData, field: field)))
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

    /// A field's value as shown, or why its bytes are not a value of its
    /// type.
    private static func fieldValue(_ data: Data, field: GATTCharacteristicDB.Field)
        -> Result<String, ValueFormatMismatch> {
        do {
            return .success(try formatValue(data, field: field))
        } catch {
            return .failure(error)
        }
    }

    /// A field's value as shown: the number, followed by the unit's name
    /// when the field has one.
    private static func formatValue(_ data: Data, field: GATTCharacteristicDB.Field)
        throws(ValueFormatMismatch) -> String {
        let (text, isNumber) = try formatted(data, field: field)
        guard isNumber, let unit = field.unit else { return text }
        return "\(text) \(unit.name)"
    }

    /// A field's value without its unit, and whether it is a number (so a
    /// unit applies to it): not "(short)", hex, text or a float's special
    /// value. An integer the GSS gives a special meaning ("value is not
    /// known") is shown as that text, never as a number. Throws for a
    /// `utf8s` field that is not valid UTF-8.
    private static func formatted(
        _ data: Data,
        field: GATTCharacteristicDB.Field
    ) throws(ValueFormatMismatch) -> (text: String, isNumber: Bool) {
        if let (bits, negative, magnitude) = integerValue(data, type: field.type) {
            if let special = field.specialValues[bits] {
                return (special, false)
            }
            guard let scale = field.scale else {
                return ("\(negative ? "-" : "")\(magnitude)", true)
            }
            guard let text = scaled(negative: negative, magnitude: magnitude, by: scale) else {
                // The generator rejects a scale that can overflow, so this
                // is not reached; it shows the raw value rather than trap.
                return ("\(negative ? "-" : "")\(magnitude) (raw; the scaled value overflows)", false)
            }
            return (text, true)
        }
        switch field.type {
        case .uint8, .uint16, .uint24, .uint32, .uint48, .uint64, .sint8, .sint16, .sint24, .sint32:
            return ("(short)", false)

        case .boolean8:
            guard data.count >= 1 else { return ("(short)", false) }
            return (String(format: "0x%02X", data[data.startIndex]), false)

        case .boolean16:
            guard data.count >= 2 else { return ("(short)", false) }
            return (String(format: "0x%04X", UInt32(littleEndian(data.prefix(2)))), false)

        case .boolean24:
            guard data.count >= 3 else { return ("(short)", false) }
            return (String(format: "0x%06X", UInt32(littleEndian(data.prefix(3)))), false)

        case .boolean32:
            guard data.count >= 4 else { return ("(short)", false) }
            return (String(format: "0x%08X", UInt32(littleEndian(data.prefix(4)))), false)

        case .medfloat16:
            return medfloat16(data)

        case .medfloat32:
            return medfloat32(data)

        case .utf8s:
            // The one strict UTF-8 check, `read -f utf8`'s: every byte is
            // kept, a leading byte-order mark included.
            return (try DataFormatter.format(data, as: .utf8), false)

        case .opaque:
            return (data.map { String(format: "%02x", $0) }.joined(), false)
        }
    }

    /// The bit pattern, sign and magnitude of an integer field, read
    /// little-endian from the first bytes of `data`; nil for a non-integer
    /// type or too few bytes.
    private static func integerValue(
        _ data: Data,
        type: GATTCharacteristicDB.FieldType
    ) -> (bits: UInt64, negative: Bool, magnitude: UInt64)? {
        let width: Int
        let signed: Bool
        switch type {
        case .uint8:  (width, signed) = (1, false)
        case .uint16: (width, signed) = (2, false)
        case .uint24: (width, signed) = (3, false)
        case .uint32: (width, signed) = (4, false)
        case .uint48: (width, signed) = (6, false)
        case .uint64: (width, signed) = (8, false)
        case .sint8:  (width, signed) = (1, true)
        case .sint16: (width, signed) = (2, true)
        case .sint24: (width, signed) = (3, true)
        case .sint32: (width, signed) = (4, true)
        case .boolean8, .boolean16, .boolean24, .boolean32, .medfloat16, .medfloat32, .utf8s, .opaque:
            return nil
        }
        guard data.count >= width else { return nil }
        let raw = littleEndian(data.prefix(width))
        let signBit = UInt64(8 * width - 1)
        guard signed, (raw >> signBit) & 1 == 1 else { return (raw, false, raw) }
        // Sign-extend, then take the magnitude (which fits: width <= 4).
        let shift = UInt64(64 - 8 * width)
        let value = Int64(bitPattern: raw << shift) >> shift
        return (raw, true, value.magnitude)
    }

    /// raw * multiplier * 10^decimalExponent * 2^binaryExponent, printed
    /// with the decimal places its resolution supports: max(0, -d) for the
    /// decimal exponent, plus ceil(k * log10 2) for b = -k (d = -2 gives 2
    /// places; b = -1 gives 1, b = -16 gives 5); b >= 0 adds none. A value
    /// with more places is rounded half away from zero (0.015625 at 5 places
    /// is 0.01563). The arithmetic is integer, so no binary floating-point
    /// error reaches the output: 2^-k is 5^k * 10^-k, so the exact value is
    /// n * 10^(d - k) for a 64-bit n. nil when the arithmetic overflows 64
    /// bits.
    static func scaled(
        negative: Bool,
        magnitude: UInt64,
        by scale: GATTCharacteristicDB.Scale
    ) -> String? {
        // n = magnitude * |M| * 5^k for b = -k, or * 2^b for b >= 0.
        let k = scale.binaryExponent < 0 ? Int(scale.binaryExponent.magnitude) : 0
        var factor: UInt64 = 1
        var overflow: Bool
        for _ in 0..<scale.binaryExponent.magnitude {
            (factor, overflow) = factor.multipliedReportingOverflow(by: k > 0 ? 5 : 2)
            guard !overflow else { return nil }
        }
        (factor, overflow) = factor.multipliedReportingOverflow(by: scale.multiplier.magnitude)
        guard !overflow else { return nil }
        var n: UInt64
        (n, overflow) = magnitude.multipliedReportingOverflow(by: factor)
        guard !overflow else { return nil }
        let exactPlaces = k - scale.decimalExponent  // the value is n * 10^-exactPlaces
        // ceil(k * log10 2) is the number of digits of 2^k, floor(k * log10 2)
        // + 1, as k * log10 2 is not an integer for k >= 1. 5^k fit in 64
        // bits above, so k < 28 and 2^k fits too.
        let binaryPlaces = k == 0 ? 0 : String(UInt64(1) << UInt64(k)).count
        let places = max(0, -scale.decimalExponent) + binaryPlaces

        var digits: String
        if exactPlaces > places {
            // Drop the extra places; the last digit dropped is the most
            // significant of them, and decides the rounding.
            var dropped: UInt64 = 0
            for _ in 0..<(exactPlaces - places) {
                dropped = n % 10
                n /= 10
            }
            if dropped >= 5 { n += 1 }
            digits = String(n)
        } else {
            digits = String(n)
            if n != 0 { digits += String(repeating: "0", count: places - exactPlaces) }
        }
        if places > 0 {
            if digits.count <= places {
                digits = String(repeating: "0", count: places + 1 - digits.count) + digits
            }
            digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -places))
        }
        let isNegative = n != 0 && negative != (scale.multiplier < 0)
        return (isNegative ? "-" : "") + digits
    }

    // IEEE 11073-20601 SFLOAT-16: 4-bit signed exponent, 12-bit signed
    // mantissa. The special values are the mantissas 0x07FE to 0x0802 with
    // exponent 0 (IEEE 11073-20601 is not vendored; the values are from its
    // SFLOAT-Type definition). With any other exponent they are numbers.
    static func decodeMedfloat16(_ data: Data) -> String { medfloat16(data).text }

    private static func medfloat16(_ data: Data) -> (text: String, isNumber: Bool) {
        guard data.count >= 2 else { return ("(short)", false) }
        let raw = data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        let expRaw = Int(raw >> 12)
        let exp = expRaw > 7 ? expRaw - 16 : expRaw
        let mantRaw = Int(raw & 0x0FFF)
        let mant = mantRaw > 0x07FF ? mantRaw - 0x1000 : mantRaw
        switch (exp, mantRaw) {
        case (0, 0x07FF): return ("NaN", false)
        case (0, 0x0800): return ("NRes", false)
        case (0, 0x07FE): return ("+Inf", false)
        case (0, 0x0802): return ("-Inf", false)
        case (0, 0x0801): return ("Reserved", false)
        default:
            let value = Double(mant) * pow(10.0, Double(exp))
            return (value == value.rounded() && abs(value) < 1e9
                ? String(format: "%.0f", value)
                : String(format: "%.6g", value), true)
        }
    }

    // IEEE 11073-20601 FLOAT-32: 8-bit signed exponent, 24-bit signed
    // mantissa. The special values are the mantissas 0x007FFFFE to
    // 0x00800002 with exponent 0, as for SFLOAT.
    static func decodeMedfloat32(_ data: Data) -> String { medfloat32(data).text }

    private static func medfloat32(_ data: Data) -> (text: String, isNumber: Bool) {
        guard data.count >= 4 else { return ("(short)", false) }
        let raw = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let exp = Int(Int8(bitPattern: UInt8(raw >> 24)))
        let mantRaw = Int(raw & 0x00FFFFFF)
        let mant = mantRaw > 0x007FFFFF ? mantRaw - 0x01000000 : mantRaw
        switch (exp, mantRaw) {
        case (0, 0x007FFFFF): return ("NaN", false)
        case (0, 0x00800000): return ("NRes", false)
        case (0, 0x007FFFFE): return ("+Inf", false)
        case (0, 0x00800002): return ("-Inf", false)
        case (0, 0x00800001): return ("Reserved", false)
        default:
            let value = Double(mant) * pow(10.0, Double(exp))
            return (value == value.rounded() && abs(value) < 1e12
                ? String(format: "%.0f", value)
                : String(format: "%.9g", value), true)
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
        case .sint24:     return "sint24"
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

/// The keys of a `condition` object in `gatt info` JSON.
private enum ConditionKey: String, CodingKey {
    case kind, field, bit, value, description, conditions
}

/// The `kind` of a `condition` object: one per `Condition` case, and
/// `allOf`, FieldInfo's wrapper for several conditions.
private enum ConditionKind: String, Codable {
    case bit, equals, notEquals, external, allOf
}

/// A presence condition as one `condition` object of `gatt info` JSON.
extension GATTCharacteristicDB.Condition: Codable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ConditionKey.self)
        switch self {
        case .bit(let field, let bit, let set):
            try container.encode(ConditionKind.bit, forKey: .kind)
            try container.encode(field, forKey: .field)
            try container.encode(bit, forKey: .bit)
            try container.encode(set ? 1 : 0, forKey: .value)
        case .equals(let field, let value):
            try container.encode(ConditionKind.equals, forKey: .kind)
            try container.encode(field, forKey: .field)
            try container.encode(value, forKey: .value)
        case .notEquals(let field, let value):
            try container.encode(ConditionKind.notEquals, forKey: .kind)
            try container.encode(field, forKey: .field)
            try container.encode(value, forKey: .value)
        case .external(let text):
            try container.encode(ConditionKind.external, forKey: .kind)
            try container.encode(text, forKey: .description)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ConditionKey.self)
        switch try container.decode(ConditionKind.self, forKey: .kind) {
        case .bit:
            let bit = try container.decode(Int.self, forKey: .bit)
            guard (0..<64).contains(bit) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .bit, in: container, debugDescription: "a bit condition needs a bit in 0...63")
            }
            let value = try container.decode(Int.self, forKey: .value)
            guard value == 0 || value == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container, debugDescription: "a bit condition needs a value of 0 or 1")
            }
            self = .bit(field: try container.decode(String.self, forKey: .field), bit: bit, set: value == 1)
        case .equals:
            self = .equals(field: try container.decode(String.self, forKey: .field),
                           value: try container.decode(UInt64.self, forKey: .value))
        case .notEquals:
            self = .notEquals(field: try container.decode(String.self, forKey: .field),
                              value: try container.decode(UInt64.self, forKey: .value))
        case .external:
            self = .external(try container.decode(String.self, forKey: .description))
        case .allOf:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "allOf cannot nest inside a condition")
        }
    }
}
