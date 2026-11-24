import XCTest
import CoreBluetooth
@testable import BLEManager
@testable import blew
#if MCP_ENABLED
import MCP
#endif

/// UUID validation at the peripheral's entry points (config file, CLI, MCP)
/// and one key per UUID inside the GATT server.
final class PeripheralUUIDTests: XCTestCase {

    // MARK: - Config file

    func testConfigRejectsMalformedServiceUUID() throws {
        let error = try loadError(config(service: "180G"))
        XCTAssertTrue(error.contains("\"180G\""), error)
        XCTAssertTrue(error.contains("services[0].uuid"), error)
    }

    func testConfigRejectsMalformedCharacteristicUUID() throws {
        let error = try loadError(config(characteristic: "2A1"))
        XCTAssertTrue(error.contains("\"2A1\""), error)
        XCTAssertTrue(error.contains("services[0].characteristics[0].uuid"), error)
    }

    func testConfigRejectsSpellingsCoreBluetoothRewrites() throws {
        // CBUUID accepts these but reports them as "180F", so a key built
        // from the text as written never matches a CoreBluetooth callback.
        for text in ["0x180F", " 180F", "180F ", "\u{FF11}\u{FF18}\u{FF10}\u{FF26}"] {
            let error = try loadError(config(service: text))
            XCTAssertTrue(error.contains("services[0].uuid: invalid UUID"), error)
        }
    }

    func testConfigRejectsClientCharacteristicConfigurationDescriptor() throws {
        let error = try loadError(config(descriptors: ["2902"]))
        XCTAssertTrue(error.contains("2902"), error)
        XCTAssertTrue(error.contains("CoreBluetooth"), error)
    }

    func testConfigRejectsDescriptorsWithoutValues() throws {
        // CBMutableDescriptor raises for 2901 and 2904 without a value, and
        // the config format has no descriptor values.
        for uuid in ["2901", "00002904-0000-1000-8000-00805F9B34FB"] {
            let error = try loadError(config(descriptors: [uuid]))
            XCTAssertTrue(error.contains("value"), error)
        }
    }

    func testConfigRejectsMalformedDescriptorUUID() throws {
        let error = try loadError(config(descriptors: ["29O2"]))
        XCTAssertTrue(error.contains("\"29O2\""), error)
    }

    func testConfigAcceptsEveryWellFormedSpelling() throws {
        for text in ["180f", "0000180F", "0000180f-0000-1000-8000-00805f9b34fb",
                     "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"] {
            let url = try writeTempFile(config(service: text))
            defer { try? FileManager.default.removeItem(at: url) }
            XCTAssertNoThrow(try PeripheralConfig.load(from: url.path), text)
        }
    }

    func testConfigRejectsOneCharacteristicUUIDInTwoSpellings() throws {
        let json = """
        { "services": [
          { "uuid": "FFF0", "primary": true,
            "characteristics": [{ "uuid": "2A19", "properties": ["read"] }] },
          { "uuid": "FFF8", "primary": true,
            "characteristics": [{ "uuid": "00002a19-0000-1000-8000-00805f9b34fb",
                                  "properties": ["read"] }] }
        ] }
        """
        let error = try loadError(json)
        XCTAssertTrue(error.contains("services[1].characteristics[0]"), error)
        XCTAssertTrue(error.contains("services[0].characteristics[0]"), error)
    }

    func testConfigErrorsNameTheLocation() throws {
        XCTAssertTrue(try loadError("{ \"services\": [ { \"uuid\": 5 } ] }")
            .contains("services[0].uuid: "))
        XCTAssertTrue(try loadError("{ \"services\": [ { \"uuid\": \"180D\" } ] }")
            .contains("services[0]: missing key \"primary\""))
        XCTAssertTrue(try loadError("{ \"services\": [ }").hasPrefix("Invalid config: "))
    }

    // MARK: - CLI

    func testPeriphCharacteristicResolution() throws {
        let known = try ["FFF1", "FFF2", "00002A19-0000-1000-8000-00805F9B34FB"]
            .map { try BLEUUID(parsing: $0) }
        let resolve = { (input: String) in
            try CommandRouter.resolvePeriphCharacteristic(input, known: known)
        }
        // Any spelling of a UUID is that UUID, registered or not.
        XCTAssertEqual(try resolve("2a19").key, "2A19")
        XCTAssertEqual(try resolve("FFF3").key, "FFF3")
        // A prefix must name exactly one registered characteristic.
        XCTAssertEqual(try resolve("00002A").key, "2A19")
        XCTAssertThrowsError(try resolve("FFF")) { error in
            XCTAssertTrue(error.localizedDescription.contains("FFF1, FFF2"), "\(error)")
        }
        XCTAssertThrowsError(try resolve("ABC")) { error in
            XCTAssertTrue(error is BLEUUID.ParseError, "\(error)")
        }
    }

    func testPeriphAdvRejectsMalformedServiceUUID() {
        let result = makeRouter().dispatch("periph adv -S 180G")
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertTrue(result.errors.joined().contains("invalid UUID \"180G\""), "\(result.errors)")
    }

    func testPeriphAdvRejectsInvalidConfigWithInvalidArguments() throws {
        let url = try writeTempFile(config(descriptors: ["2902"]))
        defer { try? FileManager.default.removeItem(at: url) }
        let result = makeRouter().dispatch("periph adv -c \(url.path)")
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertTrue(result.errors.joined().contains("2902"), "\(result.errors)")
    }

    func testPeriphSetRejectsMalformedUUID() {
        let result = makeRouter().dispatch("periph set 180G 01")
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertTrue(result.errors.joined().contains("invalid UUID \"180G\""), "\(result.errors)")
    }

    // MARK: - Keys

    private let spellings = [
        "180F", "180f", "0000180F", "0000180F-0000-1000-8000-00805F9B34FB",
        "1234180F", "1234180F-0000-1000-8000-00805F9B34FB", "0001180F",
        "0000180F-0000-1000-8000-00805F9B34FC", "180D",
        "6E400001-B5A3-F393-E0A9-E50E24DCCA9E", "6e400001-b5a3-f393-e0a9-e50e24dcca9e",
    ]

    func testEqualityAgreesWithCoreBluetooth() throws {
        for a in spellings {
            for b in spellings {
                let ours = try BLEUUID(parsing: a) == BLEUUID(parsing: b)
                XCTAssertEqual(ours, CBUUID(string: a) == CBUUID(string: b), "\(a) vs \(b)")
            }
        }
    }

    func testSpellingIsWhatCoreBluetoothReportsBack() throws {
        for text in spellings {
            let uuid = try BLEUUID(parsing: text)
            XCTAssertEqual(uuid.string, CBUUID(string: text).uuidString, text)
            XCTAssertEqual(BLEUUID(CBUUID(string: text)).key, uuid.key, text)
        }
    }

    func testKeyIsTheShortestSpelling() throws {
        XCTAssertEqual(try BLEUUID(parsing: "0000180f-0000-1000-8000-00805f9b34fb").key, "180F")
        XCTAssertEqual(try BLEUUID(parsing: "0000180F").key, "180F")
        XCTAssertEqual(try BLEUUID(parsing: "1234180F-0000-1000-8000-00805F9B34FB").key, "1234180F")
        XCTAssertEqual(try BLEUUID(parsing: "0000180F-0000-1000-8000-00805F9B34FC").key,
                       "0000180F-0000-1000-8000-00805F9B34FC")
        XCTAssertEqual(Set(try spellings.prefix(4).map { try BLEUUID(parsing: $0) }).count, 1)
    }

    func testRejectsEverythingElse() {
        for text in ["", "18", "180", "12345", "180G", "0x180F", " 180F", "180F\n",
                     "6E400001B5A3F393E0A9E50E24DCCA9E", "{6E400001-B5A3-F393-E0A9-E50E24DCCA9E}",
                     "6E400001-B5A3-F393-E0A9_E50E24DCCA9E", "\u{FF11}\u{FF18}\u{FF10}\u{FF26}"] {
            XCTAssertThrowsError(try BLEUUID(parsing: text), text.debugDescription)
        }
    }

    func testCodableKeepsTheSpelling() throws {
        let uuid = try BLEUUID(parsing: "0000180f-0000-1000-8000-00805f9b34fb")
        let json = try JSONEncoder().encode([uuid])
        XCTAssertEqual(String(data: json, encoding: .utf8), "[\"0000180F-0000-1000-8000-00805F9B34FB\"]")
        XCTAssertEqual(try JSONDecoder().decode([BLEUUID].self, from: json).first?.string, uuid.string)
    }

    func testStoreSharesValuesBetweenSpellings() throws {
        let store = GATTStore()
        store.setValue(Data([0x42]), for: try BLEUUID(parsing: "00002A19-0000-1000-8000-00805F9B34FB"))
        XCTAssertEqual(store.getValue(for: BLEUUID(CBUUID(string: "2A19"))), Data([0x42]))
        XCTAssertEqual(store.getValue(for: try BLEUUID(parsing: "00002a19")), Data([0x42]))
    }

    func testServiceContinuationMatchesCallbackInAnotherSpelling() throws {
        let delegate = BLEPeripheralDelegate(store: GATTStore())
        let configured = try BLEUUID(parsing: "0000180D-0000-1000-8000-00805F9B34FB")
        let added = expectation(description: "service registration completes")
        let ticket = delegate.withCallbacks { $0.makeTicket() }
        XCTAssertTrue(delegate.withCallbacks { $0.add(ticket, { result in
            if case .success = result { added.fulfill() }
        }) })
        XCTAssertTrue(delegate.withCallbacks { $0.issue(ticket, as: .addService(configured)) })
        delegate.peripheralManager(
            CBPeripheralManager(),
            didAdd: CBMutableService(type: CBUUID(string: "180D"), primary: true),
            error: nil)
        wait(for: [added], timeout: 2)
    }

    // MARK: - MCP

    #if MCP_ENABLED
    func testMCPAdvertiseRejectsMalformedServiceUUID() async throws {
        let params = CallTool.Parameters(
            name: "ble_periph_advertise",
            arguments: ["services": .array([.string("180G")])])
        let result = try await BlewMCPServer().handleToolCall(params)
        XCTAssertEqual(result.isError, true)
        let text = result.content.compactMap { item -> String? in
            if case .text(let t) = item { return t.text }
            return nil
        }.joined()
        XCTAssertTrue(text.contains("invalid UUID \"180G\""), text)
    }
    #endif
}

// MARK: - Helpers

private func makeRouter() -> CommandRouter {
    CommandRouter(globals: try! GlobalOptions.parse([]))
}

private func config(
    service: String = "FFF0",
    characteristic: String = "FFF1",
    descriptors: [String]? = nil
) -> String {
    let quoted = { (s: String) -> String in
        String(data: try! JSONEncoder().encode(s), encoding: .utf8)!
    }
    let descriptorField = descriptors.map {
        ", \"descriptors\": [\($0.map(quoted).joined(separator: ", "))]"
    } ?? ""
    return """
    {
      "services": [{
        "uuid": \(quoted(service)),
        "primary": true,
        "characteristics": [{
          "uuid": \(quoted(characteristic)),
          "properties": ["read"]\(descriptorField)
        }]
      }]
    }
    """
}

/// Loads `json` as a config file and returns the error message it fails with.
private func loadError(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
    let url = try writeTempFile(json)
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        _ = try PeripheralConfig.load(from: url.path)
    } catch {
        return error.localizedDescription
    }
    XCTFail("config loaded without an error", file: file, line: line)
    return ""
}

private func writeTempFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("blew-test-\(UUID().uuidString).json")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}
