import XCTest
@testable import blew

final class PeripheralConfigTests: XCTestCase {

    // MARK: - JSON parsing: valid configs

    func testParseMinimalConfig() throws {
        let json = """
        {
          "services": []
        }
        """
        let config = try decodeConfig(json)
        XCTAssertNil(config.name)
        XCTAssertEqual(config.services.count, 0)
    }

    func testParseConfigWithName() throws {
        let json = """
        {
          "name": "My Device",
          "services": []
        }
        """
        let config = try decodeConfig(json)
        XCTAssertEqual(config.name, "My Device")
    }

    func testParseConfigWithSingleService() throws {
        let json = """
        {
          "name": "Test",
          "services": [
            {
              "uuid": "180F",
              "primary": true,
              "characteristics": []
            }
          ]
        }
        """
        let config = try decodeConfig(json)
        XCTAssertEqual(config.services.count, 1)
        XCTAssertEqual(config.services[0].uuid, "180F")
        XCTAssertTrue(config.services[0].primary)
        XCTAssertEqual(config.services[0].characteristics.count, 0)
    }

    func testParseConfigWithCharacteristic() throws {
        let json = """
        {
          "services": [
            {
              "uuid": "180F",
              "primary": true,
              "characteristics": [
                {
                  "uuid": "2A19",
                  "properties": ["read", "notify"],
                  "value": "55",
                  "format": "uint8"
                }
              ]
            }
          ]
        }
        """
        let config = try decodeConfig(json)
        let char = config.services[0].characteristics[0]
        XCTAssertEqual(char.uuid, "2A19")
        XCTAssertEqual(char.properties.map { $0.rawValue }, ["read", "notify"])
        XCTAssertEqual(char.value, "55")
        XCTAssertEqual(char.format, "uint8")
    }

    func testParseConfigMultipleServices() throws {
        let json = """
        {
          "services": [
            { "uuid": "180F", "primary": true, "characteristics": [] },
            { "uuid": "180A", "primary": true, "characteristics": [] }
          ]
        }
        """
        let config = try decodeConfig(json)
        XCTAssertEqual(config.services.count, 2)
        XCTAssertEqual(config.services[0].uuid, "180F")
        XCTAssertEqual(config.services[1].uuid, "180A")
    }

    func testParseConfigHexValue() throws {
        let json = """
        {
          "services": [
            {
              "uuid": "FFF0",
              "primary": true,
              "characteristics": [
                {
                  "uuid": "FFF1",
                  "properties": ["read"],
                  "value": "deadbeef",
                  "format": "hex"
                }
              ]
            }
          ]
        }
        """
        let config = try decodeConfig(json)
        XCTAssertEqual(config.services[0].characteristics[0].value, "deadbeef")
    }

    func testParseConfigNoValueOrFormat() throws {
        let json = """
        {
          "services": [
            {
              "uuid": "FFF0",
              "primary": true,
              "characteristics": [
                {
                  "uuid": "FFF1",
                  "properties": ["write"]
                }
              ]
            }
          ]
        }
        """
        let config = try decodeConfig(json)
        let char = config.services[0].characteristics[0]
        XCTAssertNil(char.value)
        XCTAssertNil(char.format)
    }

    // MARK: - resolvedInitialValues

    func testResolvedInitialValuesEmpty() throws {
        let json = """
        { "services": [{ "uuid": "FFF0", "primary": true, "characteristics": [] }] }
        """
        let config = try decodeConfig(json)
        let values = try config.resolvedInitialValues()
        XCTAssertTrue(values.isEmpty)
    }

    func testResolvedInitialValuesHex() throws {
        let json = """
        {
          "services": [{
            "uuid": "FFF0",
            "primary": true,
            "characteristics": [{
              "uuid": "FFF1",
              "properties": ["read"],
              "value": "deadbeef",
              "format": "hex"
            }]
          }]
        }
        """
        let config = try decodeConfig(json)
        let values = try config.resolvedInitialValues()
        XCTAssertEqual(values["FFF1"], Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testResolvedInitialValuesUint8() throws {
        let json = """
        {
          "services": [{
            "uuid": "180F",
            "primary": true,
            "characteristics": [{
              "uuid": "2A19",
              "properties": ["read", "notify"],
              "value": "85",
              "format": "uint8"
            }]
          }]
        }
        """
        let config = try decodeConfig(json)
        let values = try config.resolvedInitialValues()
        XCTAssertEqual(values["2A19"], Data([85]))
    }

    func testResolvedInitialValuesDefaultFormatIsHex() throws {
        // No "format" field defaults to hex
        let json = """
        {
          "services": [{
            "uuid": "FFF0",
            "primary": true,
            "characteristics": [{
              "uuid": "FFF1",
              "properties": ["read"],
              "value": "ff"
            }]
          }]
        }
        """
        let config = try decodeConfig(json)
        let values = try config.resolvedInitialValues()
        XCTAssertEqual(values["FFF1"], Data([0xFF]))
    }

    func testResolvedInitialValuesUUIDUppercased() throws {
        let json = """
        {
          "services": [{
            "uuid": "fff0",
            "primary": true,
            "characteristics": [{
              "uuid": "fff1",
              "properties": ["read"],
              "value": "01",
              "format": "hex"
            }]
          }]
        }
        """
        let config = try decodeConfig(json)
        let values = try config.resolvedInitialValues()
        // UUID key should be uppercased
        XCTAssertNotNil(values["FFF1"])
        XCTAssertNil(values["fff1"])
    }

    func testResolvedInitialValuesNoValueSkipped() throws {
        let json = """
        {
          "services": [{
            "uuid": "FFF0",
            "primary": true,
            "characteristics": [{
              "uuid": "FFF1",
              "properties": ["write"]
            }]
          }]
        }
        """
        let config = try decodeConfig(json)
        let values = try config.resolvedInitialValues()
        XCTAssertNil(values["FFF1"])
    }

    func testResolvedInitialValuesInvalidValueThrows() throws {
        let json = """
        {
          "services": [{
            "uuid": "FFF0",
            "primary": true,
            "characteristics": [{
              "uuid": "FFF1",
              "properties": ["read"],
              "value": "not-a-uint8",
              "format": "uint8"
            }]
          }]
        }
        """
        let config = try decodeConfig(json)
        XCTAssertThrowsError(try config.resolvedInitialValues())
    }

    // MARK: - load(from:) errors

    func testLoadFromMissingFileThrows() {
        XCTAssertThrowsError(try PeripheralConfig.load(from: "/nonexistent/path/file.json")) { error in
            if let configError = error as? PeripheralConfig.ConfigError,
               case .fileNotFound(let path) = configError {
                XCTAssertEqual(path, "/nonexistent/path/file.json")
            } else {
                XCTFail("Expected ConfigError.fileNotFound, got \(error)")
            }
        }
    }

    func testLoadFromInvalidJSONThrows() throws {
        let url = try writeTempFile(contents: "{ not valid json }")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try PeripheralConfig.load(from: url.path)) { error in
            if let configError = error as? PeripheralConfig.ConfigError,
               case .invalidJSON = configError {
                // pass
            } else {
                XCTFail("Expected ConfigError.invalidJSON, got \(error)")
            }
        }
    }

    func testLoadFromValidFile() throws {
        let json = """
        { "name": "FileTest", "services": [] }
        """
        let url = try writeTempFile(contents: json)
        defer { try? FileManager.default.removeItem(at: url) }
        let config = try PeripheralConfig.load(from: url.path)
        XCTAssertEqual(config.name, "FileTest")
    }

    // MARK: - Example config files

    func testLoadHealthThermometerExample() throws {
        let examplesDir = findExamplesDir()
        guard let path = examplesDir?.appendingPathComponent("health-thermometer.json").path,
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Examples directory not found")
        }
        let config = try PeripheralConfig.load(from: path)
        XCTAssertFalse(config.services.isEmpty)
    }
}

// MARK: - Helpers

private func decodeConfig(_ json: String) throws -> PeripheralConfig {
    let data = json.data(using: .utf8)!
    return try JSONDecoder().decode(PeripheralConfig.self, from: data)
}

private func writeTempFile(contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("blew-test-\(UUID().uuidString).json")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func findExamplesDir() -> URL? {
    // Walk up from the test bundle to find the workspace root
    var url = URL(fileURLWithPath: #file)
    for _ in 0..<5 {
        url = url.deletingLastPathComponent()
        let candidate = url.appendingPathComponent("Examples")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}
