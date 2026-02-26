import Foundation

enum DataFormatter {
    static func format(_ data: Data, as fmt: String) -> String {
        switch fmt.lowercased() {
        case "hex":
            return data.map { String(format: "%02x", $0) }.joined()
        case "utf8":
            return String(data: data, encoding: .utf8) ?? format(data, as: "hex")
        case "base64":
            return data.base64EncodedString()
        case "uint8":
            guard data.count >= 1 else { return "(empty)" }
            return "\(data[data.startIndex])"
        case "uint16le":
            guard data.count >= 2 else { return "(insufficient data)" }
            let value = data.withUnsafeBytes { $0.load(as: UInt16.self) }
            return "\(value)"
        case "uint32le":
            guard data.count >= 4 else { return "(insufficient data)" }
            let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            return "\(value)"
        case "float32le":
            guard data.count >= 4 else { return "(insufficient data)" }
            let value = data.withUnsafeBytes { $0.load(as: Float32.self) }
            return "\(value)"
        case "raw":
            return data.map { String(format: "%02x", $0) }.joined(separator: " ")
        default:
            return data.map { String(format: "%02x", $0) }.joined()
        }
    }

    static func parse(_ string: String, as fmt: String) -> Data? {
        switch fmt.lowercased() {
        case "hex":
            return parseHex(string)
        case "utf8":
            return string.data(using: .utf8)
        case "base64":
            return Data(base64Encoded: string)
        case "uint8":
            guard let value = UInt8(string) else { return nil }
            return Data([value])
        case "uint16le":
            guard let value = UInt16(string) else { return nil }
            var v = value
            return Data(bytes: &v, count: 2)
        case "uint32le":
            guard let value = UInt32(string) else { return nil }
            var v = value
            return Data(bytes: &v, count: 4)
        case "float32le":
            guard let value = Float32(string) else { return nil }
            var v = value
            return Data(bytes: &v, count: 4)
        case "raw":
            return parseHex(string.replacingOccurrences(of: " ", with: ""))
        default:
            return parseHex(string)
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
