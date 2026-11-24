import XCTest
import BLEManager
@testable import blew

/// `gatt chars|tree -r -f <fmt>`: which formats a listing takes, how each
/// read value is shown in one, and how a value that does not fit the format
/// fails only its own cell in text, kv and JSON.
final class GATTListingFormatTests: XCTestCase {

    private func parse(_ args: [String]) throws -> ParsedArguments {
        let sub = args.contains("tree") ? "tree" : "chars"
        return try CommandSyntax.gattSubcommands[sub]!.parse(args)
    }

    private func kv(_ output: CommandOutput) -> String {
        captureFD(STDOUT_FILENO) { KVRenderer(verbosity: 0).render(output) }
    }

    private func text(_ output: CommandOutput) -> String {
        captureFD(STDOUT_FILENO) { TextRenderer(verbosity: 0).render(output) }
    }

    private func assertInvalidArguments(_ args: [String], _ message: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CommandRouter.listingFormat(parse(args)), file: file, line: line) { error in
            XCTAssertEqual(BlewExitCode(for: error).code, BlewExitCode.invalidArguments.code, file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription,
                          file: file, line: line)
        }
    }

    // MARK: - Parsing

    func testFormatIsTakenWithRead() throws {
        XCTAssertEqual(try CommandRouter.listingFormat(parse(["-r", "-f", "uint16le", "chars", "180F"])), .uint16le)
        XCTAssertEqual(try CommandRouter.listingFormat(parse(["tree", "-dr", "--format", "UTF8"])), .utf8)
        XCTAssertNil(try CommandRouter.listingFormat(parse(["tree", "-r"])))
    }

    func testFormatWithoutReadIsInvalid() {
        assertInvalidArguments(["-f", "hex", "chars", "180F"], "needs -r/--read")
        assertInvalidArguments(["tree", "-d", "-f", "hex"], "needs -r/--read")
    }

    func testRawAndUnknownFormatsAreInvalid() {
        assertInvalidArguments(["tree", "-r", "-f", "raw"], "not available for a listing")
        assertInvalidArguments(["tree", "-r", "-f", "bogus"], "unknown format 'bogus'")
        XCTAssertFalse(ValueFormat.listingFormats.contains(.raw))
        XCTAssertEqual(ValueFormat.listingFormats.count, ValueFormat.allCases.count - 1)
    }

    func testOtherGATTSubcommandsRejectFormat() {
        XCTAssertThrowsError(try CommandSyntax.gattSubcommands["svcs"]!.parse(["svcs", "-f", "hex"]))
        XCTAssertThrowsError(try CommandSyntax.gattSubcommands["desc"]!.parse(["desc", "-f", "hex", "2A19"]))
    }

    // MARK: - Values

    func testForcedFormatOverridesSIGDecoding() {
        // Battery Level is decoded as a percentage without -f.
        let battery = Data([0x64])
        XCTAssertNotEqual(CommandRouter.listedValue(battery, uuid: "2A19", format: nil), .value("64"))
        XCTAssertEqual(CommandRouter.listedValue(battery, uuid: "2A19", format: .hex), .value("64"))
        XCTAssertEqual(CommandRouter.listedValue(battery, uuid: "2A19", format: .uint8), .value("100"))
        XCTAssertEqual(CommandRouter.listedValue(Data("Fridge".utf8), uuid: "2A00", format: .utf8), .value("Fridge"))
        XCTAssertEqual(CommandRouter.listedValue(Data([0x34, 0x12]), uuid: "FFF1", format: .uint16le), .value("4660"))
        XCTAssertEqual(CommandRouter.listedValue(Data([1, 2]), uuid: "FFF1", format: .base64), .value("AQI="))
    }

    func testValueThatDoesNotFitTheFormatFails() {
        XCTAssertEqual(CommandRouter.listedValue(Data([1, 2, 3, 4, 5]), uuid: "FFF1", format: .uint16le),
                       .failed("uint16le takes 2 bytes, got 5"))
        XCTAssertEqual(CommandRouter.listedValue(Data([1]), uuid: "FFF1", format: .uint32le),
                       .failed("uint32le takes 4 bytes, got 1"))
        XCTAssertEqual(CommandRouter.listedValue(Data(), uuid: "FFF1", format: .uint8),
                       .failed("uint8 takes 1 byte, got 0"))
        XCTAssertEqual(CommandRouter.listedValue(Data([0xFF, 0xFE]), uuid: "FFF1", format: .utf8),
                       .failed("not valid UTF-8"))
    }

    /// Only a read the device refuses fails its own row; losing the link or
    /// Bluetooth ends the listing with that error, never a per-row value.
    func testOnlyARefusedReadFailsItsRow() throws {
        XCTAssertEqual(try CommandRouter.listedValue(failedRead: BLEError.readFailed("Encryption is insufficient.")),
                       .failed("read failed: Encryption is insufficient."))
        for error: Error in [BLEError.notConnected, BLEError.bluetoothUnavailable("off"), CancellationError()] {
            XCTAssertThrowsError(try CommandRouter.listedValue(failedRead: error), "\(error)")
        }
    }

    // MARK: - Rendering

    private func charsWithMismatch() -> CommandOutput {
        .characteristics([
            CharacteristicRow(uuid: "FFF1", name: nil, properties: ["read"],
                              listed: CommandRouter.listedValue(Data([0x34, 0x12]), uuid: "FFF1", format: .uint16le)),
            CharacteristicRow(uuid: "FFF2", name: nil, properties: ["read"],
                              listed: CommandRouter.listedValue(Data([1, 2, 3, 4, 5]), uuid: "FFF2", format: .uint16le)),
        ])
    }

    func testTextCharsShowsMismatchInItsCellOnly() {
        let lines = text(charsWithMismatch()).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.hasPrefix("FFF1") && $0.hasSuffix("4660") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("FFF2") && $0.hasSuffix("(error: uint16le takes 2 bytes, got 5)") },
                      "\(lines)")
    }

    func testKVCharsMarksMismatchAsErrorNotValue() {
        let out = kv(charsWithMismatch())
        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, out)
        XCTAssertTrue(lines[0].contains("uuid=FFF1") && lines[0].contains("value=4660"), out)
        XCTAssertTrue(lines[1].contains("uuid=FFF2") && lines[1].contains(#"error="uint16le takes 2 bytes, got 5""#), out)
        XCTAssertFalse(lines[1].contains("value="), out)
    }

    func testAllFailedValuesStillShowTheValueColumn() {
        let failed = CommandOutput.characteristics([
            CharacteristicRow(uuid: "FFF2", name: nil, properties: ["read"], listed: .failed("not valid UTF-8")),
        ])
        XCTAssertTrue(text(failed).contains("(error: not valid UTF-8)"))
        XCTAssertTrue(kv(failed).contains(#"error="not valid UTF-8""#))
    }

    private func treeWithMismatch() -> CommandOutput {
        .gattTree([GATTTreeService(uuid: "FFF0", name: nil, characteristics: [
            GATTTreeCharacteristic(uuid: "FFF1", name: nil, properties: ["read"],
                                   listed: .value("4660"), descriptors: []),
            GATTTreeCharacteristic(uuid: "FFF2", name: nil, properties: ["read"],
                                   listed: .failed("uint16le takes 2 bytes, got 5"), descriptors: []),
        ])])
    }

    func testTextTreeShowsMismatchOnItsCharacteristic() {
        let lines = text(treeWithMismatch()).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.contains("FFF1") && $0.hasSuffix("= 4660") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("FFF2") && $0.hasSuffix("(error: uint16le takes 2 bytes, got 5)")
                                       && !$0.contains("=") }, "\(lines)")
    }

    func testKVTreeMarksMismatchAsErrorNotValue() {
        let lines = kv(treeWithMismatch()).split(separator: "\n").map(String.init)
        let fff2 = lines.first { $0.contains("uuid=FFF2") } ?? ""
        XCTAssertTrue(fff2.contains(#"error="uint16le takes 2 bytes, got 5""#), "\(lines)")
        XCTAssertFalse(fff2.contains("value="), fff2)
        XCTAssertTrue(lines.contains { $0.contains("uuid=FFF1") && $0.contains("value=4660") }, "\(lines)")
    }

    /// The MCP tools' structured content: a failed value is `valueError`,
    /// with no `value`.
    func testJSONMarksMismatchAsValueError() throws {
        let row = CharacteristicRow(uuid: "FFF2", name: nil, properties: ["read"],
                                    listed: .failed("uint16le takes 2 bytes, got 5"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any]
        XCTAssertEqual(json?["valueError"] as? String, "uint16le takes 2 bytes, got 5")
        XCTAssertNil(json?["value"])
        XCTAssertNil(json?["valueFields"])
        let ok = CharacteristicRow(uuid: "FFF1", name: nil, properties: ["read"], listed: .value("4660"))
        let okJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ok)) as? [String: Any]
        XCTAssertEqual(okJSON?["value"] as? String, "4660")
        XCTAssertNil(okJSON?["valueError"])
    }
}
