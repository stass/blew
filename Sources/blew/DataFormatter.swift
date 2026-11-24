import ArgumentParser
import Foundation

/// How a characteristic value is shown or given: the `-f` of `read`,
/// `write`, `sub`, `gatt chars|tree -r` and `periph set|notify`, and a
/// peripheral config's `format`.
enum ValueFormat: String, CaseIterable, Codable, Sendable {
    case hex, utf8, base64, uint8, uint16le, uint32le, float32le, raw

    /// The format called `name`, in any letter case. Throws for any other
    /// name: an unknown format is an error, never hex.
    init(parsing name: String) throws {
        guard let format = ValueFormat(rawValue: name.lowercased()) else {
            throw InvalidArgument("unknown format '\(name)' (use \(Self.names))")
        }
        self = format
    }

    /// Every format name, for messages and help: "hex, utf8, ...".
    static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// The number of bytes one value of a fixed-size format takes, nil for
    /// a format that takes any number of bytes.
    var byteWidth: Int? {
        switch self {
        case .uint8: return MemoryLayout<UInt8>.size
        case .uint16le: return MemoryLayout<UInt16>.size
        case .uint32le: return MemoryLayout<UInt32>.size
        case .float32le: return MemoryLayout<Float32>.size
        case .hex, .utf8, .base64, .raw: return nil
        }
    }

    /// The formats a listing (`gatt chars|tree -r -f`) shows its values in:
    /// every format but `raw`, whose bytes belong on a stream, not in a
    /// table cell.
    static let listingFormats: [ValueFormat] = allCases.filter { $0 != .raw }

    /// The listing format called `name`. Throws for an unknown name and for
    /// `raw`.
    init(parsingForListing name: String) throws {
        let format = try ValueFormat(parsing: name)
        guard Self.listingFormats.contains(format) else {
            let names = Self.listingFormats.map(\.rawValue).joined(separator: ", ")
            throw InvalidArgument("format '\(format.rawValue)' is not available for a listing (use \(names))")
        }
        self = format
    }
}

/// Why a value cannot be shown in a format: its bytes are not a value of
/// that format (5 bytes as `uint16le`, invalid UTF-8 as `utf8`). A command
/// that fails with it exits with code 5 (operation failed).
struct ValueFormatMismatch: Error, LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

extension ValueFormat: ExpressibleByArgument {
    init?(argument: String) { try? self.init(parsing: argument) }
}

enum DataFormatter {
    /// `data` in `fmt` when its bytes are exactly one value of that format:
    /// `uint8` takes 1 byte, `uint16le` 2, `uint32le` and `float32le` 4,
    /// `utf8` valid UTF-8; `hex`, `base64` and `raw` take any bytes. Throws
    /// otherwise, so no command shows a number read from part of the bytes,
    /// a placeholder, or hex in place of text as the value.
    static func format(_ data: Data, as fmt: ValueFormat) throws(ValueFormatMismatch) -> String {
        if let width = fmt.byteWidth, data.count != width {
            let unit = width == 1 ? "byte" : "bytes"
            throw ValueFormatMismatch(message: "\(fmt.rawValue) takes \(width) \(unit), got \(data.count)")
        }
        switch fmt {
        case .hex:
            return hex(data)
        case .utf8:
            // Decoding repairs invalid UTF-8, so a text whose UTF-8 is not
            // the bytes was not valid. (`String(data:encoding:)` would also
            // drop a leading byte-order mark.)
            let text = String(decoding: data, as: UTF8.self)
            guard text.utf8.elementsEqual(data) else {
                throw ValueFormatMismatch(message: "not valid UTF-8")
            }
            return text
        case .base64:
            return data.base64EncodedString()
        case .uint8:
            return "\(data[data.startIndex])"
        case .uint16le:
            return "\(data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })"
        case .uint32le:
            return "\(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })"
        case .float32le:
            return "\(data.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })"
        case .raw:
            return data.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }

    /// `data` as lowercase hex, two digits a byte: the format that fits any
    /// bytes, so it cannot fail.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func parse(_ string: String, as fmt: ValueFormat) -> Data? {
        switch fmt {
        case .hex:
            return parseHex(string)
        case .utf8:
            return string.data(using: .utf8)
        case .base64:
            return Data(base64Encoded: string)
        case .uint8:
            guard let value = UInt8(string) else { return nil }
            return Data([value])
        case .uint16le:
            guard let value = UInt16(string) else { return nil }
            var v = value
            return Data(bytes: &v, count: 2)
        case .uint32le:
            guard let value = UInt32(string) else { return nil }
            var v = value
            return Data(bytes: &v, count: 4)
        case .float32le:
            guard let value = Float32(string) else { return nil }
            var v = value
            return Data(bytes: &v, count: 4)
        case .raw:
            return parseHex(string.replacingOccurrences(of: " ", with: ""))
        }
    }

    private static func parseHex(_ hex: String) -> Data? {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}
