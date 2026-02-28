import XCTest
@testable import blew

final class ArgParsingHelperTests: XCTestCase {

    private var router: CommandRouter {
        CommandRouter(globals: makeGlobals())
    }

    // MARK: - parseStringOption

    func testParseStringOptionShortForm() {
        let args = ["-n", "Thingy", "other"]
        XCTAssertEqual(router.parseStringOption(args, short: "-n", long: "--name"), "Thingy")
    }

    func testParseStringOptionLongForm() {
        let args = ["--name", "Thingy"]
        XCTAssertEqual(router.parseStringOption(args, short: "-n", long: "--name"), "Thingy")
    }

    func testParseStringOptionEqualsForm() {
        let args = ["--name=Thingy"]
        XCTAssertEqual(router.parseStringOption(args, short: "-n", long: "--name"), "Thingy")
    }

    func testParseStringOptionEqualsFormWithSpaceInValue() {
        let args = ["--name=My Device"]
        XCTAssertEqual(router.parseStringOption(args, short: "-n", long: "--name"), "My Device")
    }

    func testParseStringOptionMissingReturnsNil() {
        let args = ["-f", "hex", "2A19"]
        XCTAssertNil(router.parseStringOption(args, short: "-n", long: "--name"))
    }

    func testParseStringOptionAtEndOfArgsReturnsNil() {
        // Flag at end with no value
        let args = ["-n"]
        XCTAssertNil(router.parseStringOption(args, short: "-n", long: "--name"))
    }

    func testParseStringOptionFirstOccurrenceWins() {
        let args = ["-n", "First", "-n", "Second"]
        XCTAssertEqual(router.parseStringOption(args, short: "-n", long: "--name"), "First")
    }

    // MARK: - parseIntOption

    func testParseIntOptionValid() {
        let args = ["-R", "-65"]
        XCTAssertEqual(router.parseIntOption(args, short: "-R", long: "--rssi-min"), -65)
    }

    func testParseIntOptionZero() {
        let args = ["--rssi-min", "0"]
        XCTAssertEqual(router.parseIntOption(args, short: "-R", long: "--rssi-min"), 0)
    }

    func testParseIntOptionInvalidStringReturnsNil() {
        let args = ["-R", "notanint"]
        XCTAssertNil(router.parseIntOption(args, short: "-R", long: "--rssi-min"))
    }

    func testParseIntOptionMissingReturnsNil() {
        XCTAssertNil(router.parseIntOption([], short: "-R", long: "--rssi-min"))
    }

    func testParseIntOptionFloat() {
        // Int() does not parse "3.5"
        let args = ["-R", "3.5"]
        XCTAssertNil(router.parseIntOption(args, short: "-R", long: "--rssi-min"))
    }

    // MARK: - parseDoubleOption

    func testParseDoubleOptionValid() {
        let args = ["-t", "5.0"]
        XCTAssertEqual(router.parseDoubleOption(args, short: "-t", long: "--timeout"), 5.0)
    }

    func testParseDoubleOptionInteger() {
        let args = ["-t", "10"]
        XCTAssertEqual(router.parseDoubleOption(args, short: "-t", long: "--timeout"), 10.0)
    }

    func testParseDoubleOptionInvalidReturnsNil() {
        let args = ["-t", "abc"]
        XCTAssertNil(router.parseDoubleOption(args, short: "-t", long: "--timeout"))
    }

    func testParseDoubleOptionMissingReturnsNil() {
        XCTAssertNil(router.parseDoubleOption([], short: "-t", long: "--timeout"))
    }

    // MARK: - parseAllStringOptions

    func testParseAllStringOptionsNonePresent() {
        let args = ["-n", "Thingy"]
        let result = router.parseAllStringOptions(args, short: "-S", long: "--service")
        XCTAssertEqual(result, [])
    }

    func testParseAllStringOptionsSingle() {
        let args = ["-S", "180F"]
        XCTAssertEqual(router.parseAllStringOptions(args, short: "-S", long: "--service"), ["180F"])
    }

    func testParseAllStringOptionsMultiple() {
        let args = ["-S", "180F", "-S", "180A", "-n", "Thingy"]
        XCTAssertEqual(router.parseAllStringOptions(args, short: "-S", long: "--service"), ["180F", "180A"])
    }

    func testParseAllStringOptionsLongForm() {
        let args = ["--service", "180F", "--service", "180D"]
        XCTAssertEqual(router.parseAllStringOptions(args, short: "-S", long: "--service"), ["180F", "180D"])
    }

    func testParseAllStringOptionsMixedShortAndLong() {
        let args = ["-S", "180F", "--service", "180D"]
        XCTAssertEqual(router.parseAllStringOptions(args, short: "-S", long: "--service"), ["180F", "180D"])
    }

    func testParseAllStringOptionsEmpty() {
        XCTAssertEqual(router.parseAllStringOptions([], short: "-S", long: "--service"), [])
    }

    // MARK: - positionalArgs

    func testPositionalArgsNoFlags() {
        let args = ["gatt", "svcs"]
        let result = router.positionalArgs(args, optionsWithValue: [])
        XCTAssertEqual(result, ["gatt", "svcs"])
    }

    func testPositionalArgsSkipsOptions() {
        let args = ["-n", "Thingy", "tree"]
        let opts: Set<String> = ["-n", "--name"]
        XCTAssertEqual(router.positionalArgs(args, optionsWithValue: opts), ["tree"])
    }

    func testPositionalArgsSkipsMultipleOptions() {
        let args = ["-n", "Thingy", "-f", "hex", "2A19"]
        let opts: Set<String> = ["-n", "--name", "-f", "--format"]
        XCTAssertEqual(router.positionalArgs(args, optionsWithValue: opts), ["2A19"])
    }

    func testPositionalArgsFlagsWithoutValues() {
        // Flags (no value) should be skipped themselves but not their following token
        let args = ["-w", "scan"]
        let opts: Set<String> = ["-n"]  // -w is not in optionsWithValue
        // -w starts with -, but is not in optionsWithValue, so it's skipped as a flag
        // "scan" doesn't start with - so it's a positional
        XCTAssertEqual(router.positionalArgs(args, optionsWithValue: opts), ["scan"])
    }

    func testPositionalArgsEmpty() {
        XCTAssertEqual(router.positionalArgs([], optionsWithValue: ["-n"]), [])
    }

    func testPositionalArgsMultipleServiceUUIDs() {
        let args = ["-S", "180F", "-S", "180A", "tree"]
        let opts: Set<String> = ["-S", "--service"]
        XCTAssertEqual(router.positionalArgs(args, optionsWithValue: opts), ["tree"])
    }
}

// MARK: - Helpers

private func makeGlobals() -> GlobalOptions {
    try! GlobalOptions.parse([])
}
