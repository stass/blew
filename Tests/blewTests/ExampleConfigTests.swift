import XCTest
import BLEManager
@testable import blew

/// Every `Examples/*.json` config loads, and each characteristic of a
/// standard (GSS) UUID decodes from its initial value to a plausible
/// reading, not to "(not decoded)". `GATTDecoder` skips a field the bytes are too short for
/// without a trace, so the expected decoding is pinned per characteristic:
/// a value that does not satisfy its own flags decodes to fewer fields than
/// the pinned text and fails here.
final class ExampleConfigTests: XCTestCase {

    /// Decoded initial value of each standard characteristic in `Examples/`,
    /// keyed `<file>#<short UUID>`. A characteristic that is not here is a
    /// vendor characteristic, which has no decoding.
    private static let expectedDecodings: [String: String] = [
        "health-thermometer.json#2A1C": "Flags: 0x00 | Temperature Measurement Value (Celsius): 36.6 degree Celsius",
        "health-thermometer.json#2A1D": "2",
        "health-thermometer.json#2A21": "1",
        "blood-pressure.json#2A35": "Flags: 0x04"
            + " | Blood Pressure Measurement Compound Value - Systolic (mmHg): 120 millimetre of mercury"
            + " | Blood Pressure Measurement Compound Value - Diastolic (mmHg): 80 millimetre of mercury"
            + " | Blood Pressure Measurement Compound Value - Mean Arterial Pressure (mmHg): 93 millimetre of mercury"
            + " | Pulse Rate: 72 beats per minute",
        "blood-pressure.json#2A49": "0x0003",
        // The GSS scales 2A6E and 2A6F by 0.01 and 2A6D by 0.1.
        "environmental-sensing.json#2A6E": "23.40 degree Celsius",
        "environmental-sensing.json#2A6F": "58.12 percentage",
        "environmental-sensing.json#2A6D": "101325.0 pascal",
    ]

    private var examplesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // blewTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Examples")
    }

    private func exampleFiles() throws -> [URL] {
        let files = try FileManager.default
            .contentsOfDirectory(at: examplesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no example configs in \(examplesDirectory.path)")
        return files
    }

    func testEveryExampleConfigDecodesToTheExpectedReadings() throws {
        var decoded: [String: String] = [:]
        for file in try exampleFiles() {
            let config = try PeripheralConfig.load(from: file.path)
            let values = try config.resolvedInitialValues()
            for service in config.services {
                for characteristic in service.characteristics {
                    let uuid = characteristic.uuid.string
                    guard let value = values[characteristic.uuid],
                          let short = BLENames.shortUUID(uuid),
                          let info = GATTDecoder.info(for: short), !info.fields.isEmpty
                    else { continue }
                    // The decoder answers nil when no field decodes.
                    let text = GATTDecoder.decode(value, uuid: short) ?? "(not decoded)"
                    decoded["\(file.lastPathComponent)#\(short)"] = text
                }
            }
        }
        XCTAssertEqual(decoded, Self.expectedDecodings)
    }
}
