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
/// that format (5 bytes as `uint16le`, invalid UTF-8 as `utf8`).
struct ValueFormatMismatch: Error, Equatable {
    let message: String
}

extension ValueFormat: ExpressibleByArgument {
    init?(argument: String) { try? self.init(parsing: argument) }
}

enum DataFormatter {
    static func format(_ data: Data, as fmt: ValueFormat) -> String {
        switch fmt {
        case .hex:
            return data.map { String(format: "%02x", $0) }.joined()
        case .utf8:
            return String(data: data, encoding: .utf8) ?? format(data, as: .hex)
        case .base64:
            return data.base64EncodedString()
        case .uint8:
            guard data.count >= 1 else { return "(empty)" }
            return "\(data[data.startIndex])"
        case .uint16le:
            guard data.count >= ValueFormat.uint16le.byteWidth! else { return "(insufficient data)" }
            let value = data.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            return "\(value)"
        case .uint32le:
            guard data.count >= ValueFormat.uint32le.byteWidth! else { return "(insufficient data)" }
            let value = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return "\(value)"
        case .float32le:
            guard data.count >= ValueFormat.float32le.byteWidth! else { return "(insufficient data)" }
            let value = data.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
            return "\(value)"
        case .raw:
            return data.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }

    /// `data` in `fmt` when its bytes are exactly one value of that format:
    /// `uint8` takes 1 byte, `uint16le` 2, `uint32le` and `float32le` 4,
    /// `utf8` valid UTF-8; `hex`, `base64` and `raw` take any bytes. Throws
    /// otherwise, so a listing shows the mismatch, never a number read from
    /// part of the bytes or hex in place of text.
    static func formatExactly(_ data: Data, as fmt: ValueFormat) throws(ValueFormatMismatch) -> String {
        if fmt == .utf8 {
            guard let text = String(data: data, encoding: .utf8) else {
                throw ValueFormatMismatch(message: "not valid UTF-8")
            }
            return text
        }
        guard let width = fmt.byteWidth else { return format(data, as: fmt) }
        guard data.count == width else {
            let unit = width == 1 ? "byte" : "bytes"
            throw ValueFormatMismatch(message: "\(fmt.rawValue) takes \(width) \(unit), got \(data.count)")
        }
        return format(data, as: fmt)
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
