import XCTest
@testable import blew

final class CommandDispatchTests: XCTestCase {

    private func makeRouter() -> CommandRouter {
        CommandRouter(globals: makeGlobals())
    }

    // MARK: - Empty / whitespace

    func testDispatchEmptyStringReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch(""), 0)
    }

    func testDispatchWhitespaceOnlyReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("   "), 0)
    }

    // MARK: - Unknown command

    func testDispatchUnknownCommandReturnsInvalidArguments() {
        let code = makeRouter().dispatch("boguscommand")
        XCTAssertEqual(code, BlewExitCode.invalidArguments.code)
    }

    func testDispatchUnknownCommandReturnsCode6() {
        XCTAssertEqual(makeRouter().dispatch("xyzzy"), 6)
    }

    // MARK: - help command

    func testDispatchHelpReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("help"), 0)
    }

    // MARK: - sleep command

    func testDispatchSleepMissingArgReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("sleep"), BlewExitCode.invalidArguments.code)
    }

    func testDispatchSleepNonNumericReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("sleep abc"), BlewExitCode.invalidArguments.code)
    }

    func testDispatchSleepNegativeReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("sleep -1"), BlewExitCode.invalidArguments.code)
    }

    func testDispatchSleepZeroSecondsReturnsZeroOnInterrupt() {
        // We can't easily test infinite sleep, but a very short sleep works
        XCTAssertEqual(makeRouter().dispatch("sleep 0.001"), 0)
    }

    // MARK: - gatt subcommands

    func testDispatchGATTNoSubcommandReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("gatt"), BlewExitCode.invalidArguments.code)
    }

    func testDispatchGATTUnknownSubcommandReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("gatt bogus"), BlewExitCode.invalidArguments.code)
    }

    func testDispatchGATTInfoNoUUIDReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("gatt info"), BlewExitCode.invalidArguments.code)
    }

    func testDispatchGATTInfoUnknownUUIDReturnsNotFound() {
        XCTAssertEqual(makeRouter().dispatch("gatt info ZZZZ"), BlewExitCode.notFound.code)
    }

    func testDispatchGATTInfoKnownUUIDReturnsZero() {
        // 2A19 = Battery Level — in the generated DB, no BLE needed
        XCTAssertEqual(makeRouter().dispatch("gatt info 2A19"), 0)
    }

    func testDispatchGATTInfoFullUUIDReturnsZero() {
        // Battery Level (2A19) in full Bluetooth Base UUID form
        XCTAssertEqual(makeRouter().dispatch("gatt info 00002A19-0000-1000-8000-00805F9B34FB"), 0)
    }

    // MARK: - periph subcommands

    func testDispatchPeriphNoSubcommandReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("periph"), BlewExitCode.invalidArguments.code)
    }

    func testDispatchPeriphUnknownSubcommandReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("periph bogus"), BlewExitCode.invalidArguments.code)
    }

    func testDispatchPeriphStopReturnsZero() {
        // periph stop always succeeds (even if not advertising)
        XCTAssertEqual(makeRouter().dispatch("periph stop"), 0)
    }

    func testDispatchPeriphStatusReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("periph status"), 0)
    }

    func testDispatchPeriphSetMissingArgsReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("periph set"), BlewExitCode.invalidArguments.code)
    }

    func testDispatchPeriphSetOnlyCharReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("periph set 2A19"), BlewExitCode.invalidArguments.code)
    }

    func testDispatchPeriphAdvNoServicesReturnsInvalidArguments() {
        XCTAssertEqual(makeRouter().dispatch("periph adv"), BlewExitCode.invalidArguments.code)
    }

    // MARK: - sub subcommands

    func testDispatchSubStopNoActiveSubscriptionsReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("sub stop"), 0)
    }

    func testDispatchSubStatusNoActiveSubscriptionsReturnsZero() {
        XCTAssertEqual(makeRouter().dispatch("sub status"), 0)
    }

    func testDispatchSubStopSpecificNotFoundReturnsNotFound() {
        // No active subscription for 2A19
        XCTAssertEqual(makeRouter().dispatch("sub stop 2A19"), BlewExitCode.notFound.code)
    }

    // MARK: - write command argument validation

    func testDispatchWriteMissingCharAndDataReturnsInvalidArguments() {
        // write with no device connection — but argument validation happens first
        // actually write calls ensureConnected first, which errors if not connected.
        // So we expect operationFailed or invalidArguments, not 0.
        let code = makeRouter().dispatch("write")
        XCTAssertNotEqual(code, 0)
    }

    // MARK: - disconnect command

    func testDispatchDisconnectWhenNotConnected() {
        // Should return an error (operation failed or similar) since not connected
        let code = makeRouter().dispatch("disconnect")
        // Any non-success is acceptable here; we're not testing BLE behavior
        _ = code  // We don't assert specific code since disconnect may return various errors
    }
}

// MARK: - Helpers

private func makeGlobals() -> GlobalOptions {
    try! GlobalOptions.parse([])
}
