import Foundation
import CoreBluetooth

/// A Bluetooth UUID that `CBUUID(string:)` accepts without raising.
///
/// `CBUUID(string:)` raises an Objective-C exception, which Swift cannot
/// catch, on malformed text, and it silently rewrites some spellings it does
/// accept (`0x180F`, ` 180F`). Text from config files, command-line and MCP
/// arguments therefore becomes a `BLEUUID` through `init(parsing:)` or
/// `Decodable`, which accept exactly three forms of ASCII hex digits:
/// 4 digits (16-bit), 8 digits (32-bit) and the 8-4-4-4-12 form (128-bit).
/// Only BLEManager turns a `BLEUUID` into a `CBUUID`.
///
/// Equality and hashing use `key`, which is the same for every spelling of
/// one UUID, as `CBUUID` equality is: `180F`, `0000180F` and
/// `0000180F-0000-1000-8000-00805F9B34FB` are one UUID. Every table the GATT
/// server keeps is keyed by `BLEUUID`, so a value or a pending registration
/// is found whichever spelling the config used and CoreBluetooth reports.
/// `string` keeps the spelling as written, because CoreBluetooth registers a
/// service in the form it is given (see the peripheral section of README.md).
/// Two equal values can therefore print differently, and a dictionary keeps
/// the spelling of the key inserted first.
public struct BLEUUID: Hashable, Sendable, CustomStringConvertible {
    /// The UUID as written, uppercased. This is the text CoreBluetooth gets.
    public let string: String
    /// The shortest spelling: 4 hex digits for a UUID on the Bluetooth Base
    /// UUID whose upper 16 bits are zero, 8 for one on the Base UUID with
    /// nonzero upper bits, and the 128-bit form for every other UUID.
    public let key: String

    public struct ParseError: Error, LocalizedError, Equatable {
        public let text: String

        public var errorDescription: String? {
            "invalid UUID \"\(text)\": expected 4 or 8 hex digits, "
                + "or a 128-bit UUID such as 6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
        }
    }

    public init(parsing text: String) throws {
        guard Self.isWellFormed(text) else { throw ParseError(text: text) }
        self.init(spelling: text.uppercased())
    }

    /// A UUID CoreBluetooth reported. `CBUUID.uuidString` is always one of
    /// the three accepted forms.
    init(_ cbuuid: CBUUID) {
        self.init(spelling: cbuuid.uuidString.uppercased())
    }

    private init(spelling: String) {
        string = spelling
        key = Self.shortest(spelling)
    }

    var cbuuid: CBUUID { CBUUID(string: string) }

    public var description: String { string }

    public static func == (lhs: BLEUUID, rhs: BLEUUID) -> Bool { lhs.key == rhs.key }

    public func hash(into hasher: inout Hasher) { hasher.combine(key) }

    // MARK: - Pure helpers

    private static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    static func isWellFormed(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func isHex(_ b: UInt8) -> Bool {
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "A")...UInt8(ascii: "F"),
                 UInt8(ascii: "a")...UInt8(ascii: "f"):
                return true
            default:
                return false
            }
        }
        switch bytes.count {
        case 4, 8:
            return bytes.allSatisfy(isHex)
        case 36:
            let dashes: Set<Int> = [8, 13, 18, 23]
            return bytes.enumerated().allSatisfy { i, b in
                dashes.contains(i) ? b == UInt8(ascii: "-") : isHex(b)
            }
        default:
            return false
        }
    }

    /// Shortens an uppercased spelling in one of the three forms.
    private static func shortest(_ spelling: String) -> String {
        var s = spelling
        if s.count == 36, s.hasSuffix(baseSuffix) { s = String(s.prefix(8)) }
        if s.count == 8, s.hasPrefix("0000") { s = String(s.suffix(4)) }
        return s
    }
}

extension BLEUUID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            try self.init(parsing: text)
        } catch let error as ParseError {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: error.localizedDescription)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}
