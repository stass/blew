import Foundation
import BLEManager

// Provides human-readable names for standard Bluetooth SIG UUIDs.
// Data comes from BLENames.generated.swift (produced at build time by the GenerateBLENames plugin).
enum BLENames {
    enum Category {
        case service
        case characteristic
        case descriptor
    }

    /// The 4 uppercase hex digits of a 16-bit Bluetooth SIG UUID, in any of
    /// its spellings ("180f", "0000180F", "0000180F-0000-1000-8000-00805F9B34FB").
    /// Nil for any other UUID, including a 32-bit one, and for malformed text.
    static func shortUUID(_ uuid: String) -> String? {
        guard let key = canonicalUUID(uuid), key.count == 4 else { return nil }
        return key
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
    /// spellings of one UUID compare equal: `BLEUUID.key`. Nil when `uuid`
    /// is not a well-formed UUID.
    static func canonicalUUID(_ uuid: String) -> String? {
        (try? BLEUUID(parsing: uuid))?.key
    }
}
