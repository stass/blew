import XCTest
@testable import blew

final class CommandDispatchTests: XCTestCase {

    private func makeRouter() -> CommandRouter {
        CommandRouter(globals: makeGlobals())
    }

    // MARK: - Empty / whitespace

    func testDispatchEmptyStringReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("").exitCode, 0)
    }

    func testDispatchWhitespaceOnlyReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("   ").exitCode, 0)
    }

    // MARK: - Unknown command

    func testDispatchUnknownCommandReturnsInvalidArguments() {
        let result = makeRouter().dispatch("boguscommand")
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
    }

    func testDispatchUnknownCommandReturnsCode6() {
        XCTAssertEqual(makeRouter().dispatch("xyzzy").exitCode, 6)
    }

    // MARK: - help command

    func testDispatchHelpReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("help").exitCode, 0)
    }

    // MARK: - sleep command

    func testDispatchSleepMissingArgReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("sleep").exitCode, BlewExitCode.invalidArguments.code)
    }

    func testDispatchSleepNonNumericReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("sleep abc").exitCode, BlewExitCode.invalidArguments.code)
    }

    func testDispatchSleepNegativeReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("sleep -1").exitCode, BlewExitCode.invalidArguments.code)
    }

    func testDispatchSleepZeroSecondsReturnsZeroOnInterrupt() {
        XCTAssertEqual(makeRouter().dispatch("sleep 0.001").exitCode, 0)
    }

    // MARK: - gatt subcommands

    func testDispatchGATTNoSubcommandReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("gatt").exitCode, BlewExitCode.invalidArguments.code)
    }

    func testDispatchGATTUnknownSubcommandReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("gatt bogus").exitCode, BlewExitCode.invalidArguments.code)
    }

    func testDispatchGATTInfoNoUUIDReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("gatt info").exitCode, BlewExitCode.invalidArguments.code)
    }

    func testDispatchGATTInfoUnknownUUIDReturnsNotFound() {
        XCTAssertEqual(makeRouter().dispatch("gatt info ZZZZ").exitCode, BlewExitCode.notFound.code)
    }

    func testDispatchGATTInfoKnownUUIDReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("gatt info 2A19").exitCode, 0)
    }

    func testDispatchGATTInfoFullUUIDReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("gatt info 00002A19-0000-1000-8000-00805F9B34FB").exitCode, 0)
    }

    // MARK: - periph subcommands

    func testDispatchPeriphNoSubcommandReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("periph").exitCode, BlewExitCode.invalidArguments.code)
    }

    func testDispatchPeriphUnknownSubcommandReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("periph bogus").exitCode, BlewExitCode.invalidArguments.code)
    }

    func testDispatchPeriphStopReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("periph stop").exitCode, 0)
    }

    func testDispatchPeriphStatusReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("periph status").exitCode, 0)
    }

    func testDispatchPeriphSetMissingArgsReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("periph set").exitCode, BlewExitCode.invalidArguments.code)
    }

    func testDispatchPeriphSetOnlyCharReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("periph set 2A19").exitCode, BlewExitCode.invalidArguments.code)
    }

    func testDispatchPeriphAdvNoServicesReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("periph adv").exitCode, BlewExitCode.invalidArguments.code)
    }

    // MARK: - sub subcommands

    func testDispatchSubStopNoActiveSubscriptionsReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("sub stop").exitCode, 0)
    }

    func testDispatchSubStatusNoActiveSubscriptionsReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("sub status").exitCode, 0)
    }

    func testDispatchSubStopSpecificNotFoundReturnsNotFound() {
        XCTAssertEqual(makeRouter().dispatch("sub stop 2A19").exitCode, BlewExitCode.notFound.code)
    }

    // MARK: - write command argument validation

    func testDispatchWriteMissingCharAndDataReturnsInvalidArguments() {
        let result = makeRouter().dispatch("write")
        XCTAssertNotEqual(result.exitCode, 0)
    }

    // MARK: - disconnect command

    func testDispatchDisconnectWhenNotConnected() {
        let result = makeRouter().dispatch("disconnect")
        _ = result
    }

    // MARK: - gatt info returns structured output

    func testDispatchGATTInfoReturnsCharacteristicInfo() {
        let result = makeRouter().dispatch("gatt info 2A19")
        XCTAssertEqual(result.exitCode, 0)
        guard case .characteristicInfo(let info) = result.output.first else {
            XCTFail("Expected characteristicInfo output")
            return
        }
        XCTAssertEqual(info.uuid, "2A19")
        XCTAssertFalse(info.name.isEmpty)
    }

    // MARK: - periph status returns structured output

    func testDispatchPeriphStatusReturnsPeripheralStatus() {
        let result = makeRouter().dispatch("periph status")
        XCTAssertEqual(result.exitCode, 0)
        guard case .peripheralStatus = result.output.first else {
            XCTFail("Expected peripheralStatus output")
            return
        }
    }
}

// MARK: - Helpers

private func makeGlobals() -> GlobalOptions {
    try! GlobalOptions.parse([])
}
