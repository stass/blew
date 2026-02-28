import XCTest
@testable import blew

final class ExitCodeTests: XCTestCase {

    // MARK: - Code values

    func testSuccessCode() {
        XCTAssertEqual(BlewExitCode.success.code, 0)
    }

    func testNotFoundCode() {
        XCTAssertEqual(BlewExitCode.notFound.code, 2)
    }

    func testBluetoothUnavailableCode() {
        XCTAssertEqual(BlewExitCode.bluetoothUnavailable.code, 3)
    }

    func testTimeoutCode() {
        XCTAssertEqual(BlewExitCode.timeout.code, 4)
    }

    func testOperationFailedCode() {
        XCTAssertEqual(BlewExitCode.operationFailed.code, 5)
    }

    func testInvalidArgumentsCode() {
        XCTAssertEqual(BlewExitCode.invalidArguments.code, 6)
    }

    // MARK: - CustomNSError conformance

    func testErrorDomain() {
        XCTAssertEqual(BlewExitCode.errorDomain, "blew")
    }

    func testErrorCodeMatchesCode() {
        XCTAssertEqual(BlewExitCode.notFound.errorCode, 2)
        XCTAssertEqual(BlewExitCode.invalidArguments.errorCode, 6)
    }

    func testErrorUserInfoContainsDescription() {
        let info = BlewExitCode.operationFailed.errorUserInfo
        XCTAssertNotNil(info[NSLocalizedDescriptionKey])
    }

    // MARK: - CustomStringConvertible

    func testDescriptionContainsCode() {
        XCTAssertTrue(BlewExitCode.notFound.description.contains("2"))
        XCTAssertTrue(BlewExitCode.invalidArguments.description.contains("6"))
    }

    // MARK: - Initializer

    func testCustomCodeInitializer() {
        let code = BlewExitCode(42)
        XCTAssertEqual(code.code, 42)
        XCTAssertEqual(code.errorCode, 42)
    }

    func testIsError() {
        // BlewExitCode conforms to Error; verify it can be assigned to Error variable
        let error: Error = BlewExitCode.success
        XCTAssertNotNil(error)
    }
}

final class DeviceTargetingOptionsTests: XCTestCase {

    // MARK: - toArgs() serialization

    func testAllNilOptionsProduceEmptyArray() {
        let opts = try! DeviceTargetingOptions.parse([])
        XCTAssertEqual(opts.toArgs(), [])
    }

    func testIDOptionSerialized() {
        var opts = try! DeviceTargetingOptions.parse([])
        opts.id = "F3C2A1B0-1234-5678-ABCD-000000000001"
        let args = opts.toArgs()
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("F3C2A1B0-1234-5678-ABCD-000000000001"))
    }

    func testNameOptionSerialized() {
        var opts = try! DeviceTargetingOptions.parse([])
        opts.name = "Thingy"
        let args = opts.toArgs()
        XCTAssertTrue(args.contains("-n"))
        XCTAssertTrue(args.contains("Thingy"))
    }

    func testServiceOptionSerialized() {
        var opts = try! DeviceTargetingOptions.parse([])
        opts.service = ["180F"]
        let args = opts.toArgs()
        XCTAssertTrue(args.contains("-S"))
        XCTAssertTrue(args.contains("180F"))
    }

    func testMultipleServicesAllSerialized() {
        var opts = try! DeviceTargetingOptions.parse([])
        opts.service = ["180F", "180A", "180D"]
        let args = opts.toArgs()
        let sFlags = args.indices.filter { args[$0] == "-S" }
        XCTAssertEqual(sFlags.count, 3)
        XCTAssertTrue(args.contains("180F"))
        XCTAssertTrue(args.contains("180A"))
        XCTAssertTrue(args.contains("180D"))
    }

    func testManufacturerOptionSerialized() {
        var opts = try! DeviceTargetingOptions.parse([])
        opts.manufacturer = 0x004C
        let args = opts.toArgs()
        XCTAssertTrue(args.contains("-m"))
        XCTAssertTrue(args.contains("76"))
    }

    func testRSSIMinOptionSerialized() {
        var opts = try! DeviceTargetingOptions.parse([])
        opts.rssiMin = -70
        let args = opts.toArgs()
        XCTAssertTrue(args.contains("-R"))
        XCTAssertTrue(args.contains("-70"))
    }

    func testDefaultPickStrategyNotIncluded() {
        var opts = try! DeviceTargetingOptions.parse([])
        opts.pick = .strongest  // default
        let args = opts.toArgs()
        XCTAssertFalse(args.contains("-p"))
        XCTAssertFalse(args.contains("strongest"))
    }

    func testNonDefaultPickStrategySerialized() {
        var opts = try! DeviceTargetingOptions.parse([])
        opts.pick = .only
        let args = opts.toArgs()
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("only"))
    }

    func testFirstPickStrategySerialized() {
        var opts = try! DeviceTargetingOptions.parse([])
        opts.pick = .first
        let args = opts.toArgs()
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("first"))
    }

    func testAllOptionsCombined() {
        var opts = try! DeviceTargetingOptions.parse([])
        opts.id = "SOME-UUID"
        opts.name = "MyDevice"
        opts.service = ["180F"]
        opts.manufacturer = 10
        opts.rssiMin = -65
        opts.pick = .first
        let args = opts.toArgs()
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("SOME-UUID"))
        XCTAssertTrue(args.contains("-n"))
        XCTAssertTrue(args.contains("MyDevice"))
        XCTAssertTrue(args.contains("-S"))
        XCTAssertTrue(args.contains("180F"))
        XCTAssertTrue(args.contains("-m"))
        XCTAssertTrue(args.contains("-R"))
        XCTAssertTrue(args.contains("-65"))
        XCTAssertTrue(args.contains("-p"))
        XCTAssertTrue(args.contains("first"))
    }

    // MARK: - PickStrategy raw values

    func testPickStrategyRawValues() {
        XCTAssertEqual(PickStrategy.strongest.rawValue, "strongest")
        XCTAssertEqual(PickStrategy.first.rawValue, "first")
        XCTAssertEqual(PickStrategy.only.rawValue, "only")
    }

    func testPickStrategyFromRawValue() {
        XCTAssertEqual(PickStrategy(rawValue: "strongest"), .strongest)
        XCTAssertEqual(PickStrategy(rawValue: "first"), .first)
        XCTAssertEqual(PickStrategy(rawValue: "only"), .only)
        XCTAssertNil(PickStrategy(rawValue: "bogus"))
    }

    // MARK: - OutputFormat raw values

    func testOutputFormatRawValues() {
        XCTAssertEqual(OutputFormat.text.rawValue, "text")
        XCTAssertEqual(OutputFormat.kv.rawValue, "kv")
    }

    func testOutputFormatFromRawValue() {
        XCTAssertEqual(OutputFormat(rawValue: "text"), .text)
        XCTAssertEqual(OutputFormat(rawValue: "kv"), .kv)
        XCTAssertNil(OutputFormat(rawValue: "json"))
    }
}
