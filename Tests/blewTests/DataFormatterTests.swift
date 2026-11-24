import XCTest
@testable import blew

final class DataFormatterTests: XCTestCase {

    // MARK: - format: hex

    func testFormatHex() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(DataFormatter.format(data, as: .hex), "deadbeef")
    }

    func testFormatHexEmpty() {
        XCTAssertEqual(DataFormatter.format(Data(), as: .hex), "")
    }

    func testFormatHexSingleByte() {
        XCTAssertEqual(DataFormatter.format(Data([0x0A]), as: .hex), "0a")
    }

    // MARK: - format: raw

    func testFormatRaw() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(DataFormatter.format(data, as: .raw), "de ad be ef")
    }

    func testFormatRawSingleByte() {
        XCTAssertEqual(DataFormatter.format(Data([0xFF]), as: .raw), "ff")
    }

    func testFormatRawEmpty() {
        XCTAssertEqual(DataFormatter.format(Data(), as: .raw), "")
    }

    // MARK: - format: utf8

    func testFormatUTF8() {
        let data = "hello".data(using: .utf8)!
        XCTAssertEqual(DataFormatter.format(data, as: .utf8), "hello")
    }

    func testFormatUTF8FallsBackToHexOnInvalidData() {
        // 0xFF is not valid UTF-8
        let data = Data([0xFF, 0xFE])
        let result = DataFormatter.format(data, as: .utf8)
        // Falls back to hex
        XCTAssertEqual(result, "fffe")
    }

    // MARK: - format: base64

    func testFormatBase64() {
        let data = Data([0x00, 0x01, 0x02])
        XCTAssertEqual(DataFormatter.format(data, as: .base64), "AAEC")
    }

    func testFormatBase64RoundTrip() {
        let data = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let encoded = DataFormatter.format(data, as: .base64)
        let decoded = DataFormatter.parse(encoded, as: .base64)
        XCTAssertEqual(decoded, data)
    }

    // MARK: - format: uint8

    func testFormatUint8() {
        XCTAssertEqual(DataFormatter.format(Data([42]), as: .uint8), "42")
    }

    func testFormatUint8Max() {
        XCTAssertEqual(DataFormatter.format(Data([255]), as: .uint8), "255")
    }

    func testFormatUint8Zero() {
        XCTAssertEqual(DataFormatter.format(Data([0]), as: .uint8), "0")
    }

    func testFormatUint8EmptyData() {
        XCTAssertEqual(DataFormatter.format(Data(), as: .uint8), "(empty)")
    }

    // MARK: - format: uint16le

    func testFormatUint16LE() {
        // 0x0100 little-endian = 256
        let data = Data([0x00, 0x01])
        XCTAssertEqual(DataFormatter.format(data, as: .uint16le), "256")
    }

    func testFormatUint16LEInsufficientData() {
        XCTAssertEqual(DataFormatter.format(Data([0x01]), as: .uint16le), "(insufficient data)")
    }

    func testFormatUint16LEMax() {
        let data = Data([0xFF, 0xFF])
        XCTAssertEqual(DataFormatter.format(data, as: .uint16le), "65535")
    }

    // MARK: - format: uint32le

    func testFormatUint32LE() {
        // 0x00000001 little-endian = 1
        let data = Data([0x01, 0x00, 0x00, 0x00])
        XCTAssertEqual(DataFormatter.format(data, as: .uint32le), "1")
    }

    func testFormatUint32LEInsufficientData() {
        XCTAssertEqual(DataFormatter.format(Data([0x01, 0x02]), as: .uint32le), "(insufficient data)")
    }

    // MARK: - format: float32le

    func testFormatFloat32LE() {
        var value: Float32 = 1.0
        let data = Data(bytes: &value, count: 4)
        XCTAssertEqual(DataFormatter.format(data, as: .float32le), "1.0")
    }

    func testFormatFloat32LEInsufficientData() {
        XCTAssertEqual(DataFormatter.format(Data([0x01, 0x02]), as: .float32le), "(insufficient data)")
    }

    // MARK: - format names

    func testUnknownFormatNameIsAnError() {
        XCTAssertThrowsError(try ValueFormat(parsing: "unknown")) { error in
            XCTAssertEqual("\(error)", "unknown format 'unknown' (use \(ValueFormat.names))")
        }
    }

    func testFormatNameIsCaseInsensitive() throws {
        XCTAssertEqual(try ValueFormat(parsing: "UINT8"), .uint8)
        XCTAssertEqual(try ValueFormat(parsing: "HEX"), .hex)
        XCTAssertEqual(try ValueFormat(parsing: "Hex"), .hex)
    }

    // MARK: - parse: hex

    func testParseHex() {
        XCTAssertEqual(DataFormatter.parse("deadbeef", as: .hex), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testParseHexUppercase() {
        XCTAssertEqual(DataFormatter.parse("DEADBEEF", as: .hex), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testParseHexEmpty() {
        XCTAssertEqual(DataFormatter.parse("", as: .hex), Data())
    }

    func testParseHexOddLengthReturnsNil() {
        XCTAssertNil(DataFormatter.parse("abc", as: .hex))
    }

    func testParseHexInvalidCharsReturnsNil() {
        XCTAssertNil(DataFormatter.parse("zz", as: .hex))
    }

    func testParseHexStripsSpaces() {
        // "raw" strips spaces; "hex" should also strip spaces
        XCTAssertEqual(DataFormatter.parse("de ad", as: .hex), Data([0xDE, 0xAD]))
    }

    // MARK: - parse: raw

    func testParseRaw() {
        XCTAssertEqual(DataFormatter.parse("de ad be ef", as: .raw), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testParseRawNoSpaces() {
        XCTAssertEqual(DataFormatter.parse("deadbeef", as: .raw), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    // MARK: - parse: utf8

    func testParseUTF8() {
        XCTAssertEqual(DataFormatter.parse("hello", as: .utf8), "hello".data(using: .utf8))
    }

    func testParseUTF8Empty() {
        XCTAssertEqual(DataFormatter.parse("", as: .utf8), Data())
    }

    // MARK: - parse: base64

    func testParseBase64() {
        XCTAssertEqual(DataFormatter.parse("AAEC", as: .base64), Data([0x00, 0x01, 0x02]))
    }

    func testParseBase64Invalid() {
        XCTAssertNil(DataFormatter.parse("not!base64!!", as: .base64))
    }

    // MARK: - parse: uint8

    func testParseUint8() {
        XCTAssertEqual(DataFormatter.parse("42", as: .uint8), Data([42]))
    }

    func testParseUint8Max() {
        XCTAssertEqual(DataFormatter.parse("255", as: .uint8), Data([255]))
    }

    func testParseUint8Overflow() {
        XCTAssertNil(DataFormatter.parse("256", as: .uint8))
    }

    func testParseUint8Negative() {
        XCTAssertNil(DataFormatter.parse("-1", as: .uint8))
    }

    func testParseUint8NonNumeric() {
        XCTAssertNil(DataFormatter.parse("abc", as: .uint8))
    }

    // MARK: - parse: uint16le

    func testParseUint16LE() {
        let result = DataFormatter.parse("256", as: .uint16le)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 2)
        // 256 = 0x0100 little-endian = [0x00, 0x01]
        XCTAssertEqual(result, Data([0x00, 0x01]))
    }

    func testParseUint16LEMax() {
        let result = DataFormatter.parse("65535", as: .uint16le)
        XCTAssertEqual(result, Data([0xFF, 0xFF]))
    }

    func testParseUint16LEInvalid() {
        XCTAssertNil(DataFormatter.parse("notanumber", as: .uint16le))
    }

    // MARK: - parse: uint32le

    func testParseUint32LE() {
        let result = DataFormatter.parse("1", as: .uint32le)
        XCTAssertEqual(result, Data([0x01, 0x00, 0x00, 0x00]))
    }

    func testParseUint32LEInvalid() {
        XCTAssertNil(DataFormatter.parse("bogus", as: .uint32le))
    }

    // MARK: - parse: float32le

    func testParseFloat32LE() {
        let result = DataFormatter.parse("1.0", as: .float32le)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 4)
        let value = result!.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }
        XCTAssertEqual(value, 1.0, accuracy: 0.0001)
    }

    func testParseFloat32LEInvalid() {
        XCTAssertNil(DataFormatter.parse("notafloat", as: .float32le))
    }

    // MARK: - Round-trip tests

    func testRoundTripHex() {
        let original = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let formatted = DataFormatter.format(original, as: .hex)
        let parsed = DataFormatter.parse(formatted, as: .hex)
        XCTAssertEqual(parsed, original)
    }

    func testRoundTripUTF8() {
        let original = "Hello, world!".data(using: .utf8)!
        let formatted = DataFormatter.format(original, as: .utf8)
        let parsed = DataFormatter.parse(formatted, as: .utf8)
        XCTAssertEqual(parsed, original)
    }

    func testRoundTripUint8() {
        let original = Data([99])
        let formatted = DataFormatter.format(original, as: .uint8)
        let parsed = DataFormatter.parse(formatted, as: .uint8)
        XCTAssertEqual(parsed, original)
    }

    func testRoundTripUint16LE() {
        let original = Data([0x39, 0x05])  // 1337 in LE
        let formatted = DataFormatter.format(original, as: .uint16le)
        let parsed = DataFormatter.parse(formatted, as: .uint16le)
        XCTAssertEqual(parsed, original)
    }

    func testRoundTripUint32LE() {
        let original = Data([0xD2, 0x04, 0x00, 0x00])  // 1234 in LE
        let formatted = DataFormatter.format(original, as: .uint32le)
        let parsed = DataFormatter.parse(formatted, as: .uint32le)
        XCTAssertEqual(parsed, original)
    }

    func testRoundTripRaw() {
        let original = Data([0x01, 0x23, 0x45])
        let formatted = DataFormatter.format(original, as: .raw)
        let parsed = DataFormatter.parse(formatted, as: .raw)
        XCTAssertEqual(parsed, original)
    }
}

/// Decoders receive `Data` slices whose bytes need not be aligned for the
/// integer or float type being read (a notification payload sliced past its
/// first byte, for example). Reading them must not trap.
final class UnalignedDecodeTests: XCTestCase {

    /// Heap-backed bytes viewed from offset 1, so the slice's base pointer is
    /// odd and therefore misaligned for every multi-byte type.
    private func misaligned(_ bytes: [UInt8]) -> Data {
        let padded = Data([0xAA] + bytes + [UInt8](repeating: 0, count: 32))
        return padded.dropFirst().prefix(bytes.count)
    }

    func testFormatterReadsMisalignedIntegersAndFloats() {
        XCTAssertEqual(DataFormatter.format(misaligned([0x34, 0x12]), as: .uint16le), "4660")
        XCTAssertEqual(DataFormatter.format(misaligned([0x78, 0x56, 0x34, 0x12]), as: .uint32le), "305419896")
        XCTAssertEqual(DataFormatter.format(misaligned([0x00, 0x00, 0xC0, 0x3F]), as: .float32le), "1.5")
    }

    /// GATTDecoder copies each field into its own buffer before reading it,
    /// so this checks that decoding a misaligned slice gives the right values
    /// rather than reaching a misaligned read directly.
    func testGATTDecoderDecodesMisalignedSlices() {
        XCTAssertEqual(GATTDecoder.decode(misaligned([0x34, 0x12]), uuid: "2A6E"), "46.60 degree Celsius")
        XCTAssertEqual(GATTDecoder.decode(misaligned([0x78, 0x56, 0x34, 0x12]), uuid: "2A6D"), "30541989.6 pascal")
        XCTAssertEqual(GATTDecoder.decode(misaligned([0x00, 0x72, 0x01, 0x00, 0xFF]), uuid: "2A1C"), "Flags: 0x00 | Temperature Measurement Value (Celsius): 37 degree Celsius")
    }
}
