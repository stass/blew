import Foundation

// Provides human-readable names for standard Bluetooth SIG UUIDs.
// Data comes from BLENames.generated.swift (produced at build time by the GenerateBLENames plugin).
enum BLENames {
    enum Category {
        case service
        case characteristic
        case descriptor
    }

    // Bluetooth Base UUID suffix: -0000-1000-8000-00805F9B34FB
    // Standard 16-bit UUIDs are embedded as 0000XXXX-0000-1000-8000-00805F9B34FB.
    private static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    /// Extract the uppercase 4-char hex short UUID if this is a Bluetooth Base UUID,
    /// or normalise an already-short UUID to uppercase.
    /// Returns nil for custom 128-bit UUIDs that don't use the Bluetooth Base.
    static func shortUUID(_ uuid: String) -> String? {
        let upper = uuid.uppercased()
        // Already short form: 4 hex chars (e.g. "180F") or 8 hex chars (32-bit form "0000180F")
        if upper.count == 4, upper.allSatisfy({ $0.isHexDigit }) {
            return upper
        }
        if upper.count == 8, upper.allSatisfy({ $0.isHexDigit }) {
            // 32-bit form — return lower 4 digits (the significant part)
            return String(upper.suffix(4))
        }
        // Full 128-bit: 0000XXXX-0000-1000-8000-00805F9B34FB
        guard upper.count == 36 else { return nil }
        guard upper.hasSuffix(baseSuffix.uppercased()) else { return nil }
        // Extract chars 4-8 (the significant 16-bit portion within "0000XXXX")
        let start = upper.index(upper.startIndex, offsetBy: 4)
        let end = upper.index(upper.startIndex, offsetBy: 8)
        return String(upper[start..<end])
    }

    /// Look up a human-readable name for a UUID.
    /// Accepts short form ("180F"), 32-bit form ("0000180F"), or full 128-bit Bluetooth Base UUID.
    /// Returns nil for unknown or custom (non-SIG-base) UUIDs.
    static func name(for uuid: String, category: Category) -> String? {
        guard let short = shortUUID(uuid) else { return nil }
        switch category {
        case .service:        return BLENameData.services[short]
        case .characteristic: return BLENameData.characteristics[short]
        case .descriptor:     return BLENameData.descriptors[short]
        }
    }

    /// Returns "XXXX (Human Name)" when a name is known, or just "XXXX" otherwise.
    /// Uses the original uuid string as-is for display; appends the name in parentheses.
    static func displayUUID(_ uuid: String, category: Category) -> String {
        guard let n = name(for: uuid, category: category) else { return uuid }
        return "\(uuid) (\(n))"
    }

    /// The form CoreBluetooth gives a UUID (`CBUUID.uuidString`), so two
    /// spellings of one UUID compare equal: 4 hex digits for a 16-bit
    /// Bluetooth Base UUID, 8 for a 32-bit one, otherwise the 36-character
    /// 128-bit form, all uppercase. Accepts each of those forms and the
    /// 128-bit spelling of a Base UUID. Nil when `uuid` is none of them.
    static func canonicalUUID(_ uuid: String) -> String? {
        let upper = uuid.uppercased()
        let isHex = upper.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("A"..."F").contains($0) }
        switch upper.count {
        case 4 where isHex:
            return upper
        case 8 where isHex:
            return upper.hasPrefix("0000") ? String(upper.suffix(4)) : upper
        case 36:
            guard UUID(uuidString: upper) != nil else { return nil }
            guard upper.hasSuffix(baseSuffix) else { return upper }
            return canonicalUUID(String(upper.prefix(8)))
        default:
            return nil
        }
    }
}
