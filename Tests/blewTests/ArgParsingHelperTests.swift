import XCTest
@testable import blew

final class ArgParsingHelperTests: XCTestCase {

    private var router: CommandRouter {
        CommandRouter(globals: makeGlobals())
    }

    // MARK: - parseStringOption

    func testParseStringOptionShortForm() {
        let args = ["-n", "Thingy", "other"]
        XCTAssertEqual(router.parseStringOption(args, short: "-n", long: "--name", optionsWithValue: []), "Thingy")
    }

    func testParseStringOptionLongForm() {
        let args = ["--name", "Thingy"]
        XCTAssertEqual(router.parseStringOption(args, short: "-n", long: "--name", optionsWithValue: []), "Thingy")
    }

    func testParseStringOptionEqualsForm() {
        let args = ["--name=Thingy"]
        XCTAssertEqual(router.parseStringOption(args, short: "-n", long: "--name", optionsWithValue: []), "Thingy")
    }

    func testParseStringOptionEqualsFormWithSpaceInValue() {
        let args = ["--name=My Device"]
        XCTAssertEqual(router.parseStringOption(args, short: "-n", long: "--name", optionsWithValue: []), "My Device")
    }

    func testParseStringOptionMissingReturnsNil() {
        let args = ["-f", "hex", "2A19"]
        XCTAssertNil(router.parseStringOption(args, short: "-n", long: "--name", optionsWithValue: []))
    }

    func testParseStringOptionAtEndOfArgsReturnsNil() {
        // Flag at end with no value
        let args = ["-n"]
        XCTAssertNil(router.parseStringOption(args, short: "-n", long: "--name", optionsWithValue: []))
    }

    func testParseStringOptionFirstOccurrenceWins() {
        let args = ["-n", "First", "-n", "Second"]
        XCTAssertEqual(router.parseStringOption(args, short: "-n", long: "--name", optionsWithValue: []), "First")
    }

func testOptionValuesAreNeverReadAsOptions() {
    let args = ["-p", "--name=Spoof", "-n", "-S", "-S", "180F"]
    let options = CommandRouter.targetingOptionsWithValue
    XCTAssertEqual(router.parseStringOption(args, short: "-n", long: "--name", optionsWithValue: options), "-S")
    XCTAssertEqual(router.parseAllStringOptions(args, short: "-S", long: "--service", optionsWithValue: options), ["180F"])
    XCTAssertFalse(router.hasFlag(["-n", "-r"], short: "-r", long: "--read", optionsWithValue: options))
    XCTAssertTrue(router.hasFlag(["-n", "x", "-r"], short: "-r", long: "--read", optionsWithValue: options))
}

    // MARK: - parseIntOption

    func testParseIntOptionValid() {
        let args = ["-R", "-65"]
        XCTAssertEqual(router.parseIntOption(args, short: "-R", long: "--rssi-min", optionsWithValue: []), -65)
    }

    func testParseIntOptionZero() {
        let args = ["--rssi-min", "0"]
        XCTAssertEqual(router.parseIntOption(args, short: "-R", long: "--rssi-min", optionsWithValue: []), 0)
    }

    func testParseIntOptionInvalidStringReturnsNil() {
        let args = ["-R", "notanint"]
        XCTAssertNil(router.parseIntOption(args, short: "-R", long: "--rssi-min", optionsWithValue: []))
    }

    func testParseIntOptionMissingReturnsNil() {
        XCTAssertNil(router.parseIntOption([], short: "-R", long: "--rssi-min", optionsWithValue: []))
    }

    func testParseIntOptionFloat() {
        // Int() does not parse "3.5"
        let args = ["-R", "3.5"]
        XCTAssertNil(router.parseIntOption(args, short: "-R", long: "--rssi-min", optionsWithValue: []))
    }

    // MARK: - parseDoubleOption

    func testParseDoubleOptionValid() {
        let args = ["-t", "5.0"]
        XCTAssertEqual(router.parseDoubleOption(args, short: "-t", long: "--timeout", optionsWithValue: []), 5.0)
    }

    func testParseDoubleOptionInteger() {
        let args = ["-t", "10"]
        XCTAssertEqual(router.parseDoubleOption(args, short: "-t", long: "--timeout", optionsWithValue: []), 10.0)
    }

    func testParseDoubleOptionInvalidReturnsNil() {
        let args = ["-t", "abc"]
        XCTAssertNil(router.parseDoubleOption(args, short: "-t", long: "--timeout", optionsWithValue: []))
    }

    func testParseDoubleOptionMissingReturnsNil() {
        XCTAssertNil(router.parseDoubleOption([], short: "-t", long: "--timeout", optionsWithValue: []))
    }

    // MARK: - parseAllStringOptions

    func testParseAllStringOptionsNonePresent() {
        let args = ["-n", "Thingy"]
        let result = router.parseAllStringOptions(args, short: "-S", long: "--service", optionsWithValue: [])
        XCTAssertEqual(result, [])
    }

    func testParseAllStringOptionsSingle() {
        let args = ["-S", "180F"]
        XCTAssertEqual(router.parseAllStringOptions(args, short: "-S", long: "--service", optionsWithValue: []), ["180F"])
    }

    func testParseAllStringOptionsMultiple() {
        let args = ["-S", "180F", "-S", "180A", "-n", "Thingy"]
        XCTAssertEqual(router.parseAllStringOptions(args, short: "-S", long: "--service", optionsWithValue: []), ["180F", "180A"])
    }

    func testParseAllStringOptionsLongForm() {
        let args = ["--service", "180F", "--service", "180D"]
        XCTAssertEqual(router.parseAllStringOptions(args, short: "-S", long: "--service", optionsWithValue: []), ["180F", "180D"])
    }

    func testParseAllStringOptionsMixedShortAndLong() {
        let args = ["-S", "180F", "--service", "180D"]
        XCTAssertEqual(router.parseAllStringOptions(args, short: "-S", long: "--service", optionsWithValue: []), ["180F", "180D"])
    }

    func testParseAllStringOptionsEmpty() {
        XCTAssertEqual(router.parseAllStringOptions([], short: "-S", long: "--service", optionsWithValue: []), [])
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

    // MARK: - expandArgs

    func testExpandArgsCombinedTwoFlags() {
        XCTAssertEqual(router.expandArgs(["-dr"]), ["-d", "-r"])
    }

    func testExpandArgsCombinedThreeFlags() {
        XCTAssertEqual(router.expandArgs(["-drw"]), ["-d", "-r", "-w"])
    }

    func testExpandArgsSingleFlagPassthrough() {
        XCTAssertEqual(router.expandArgs(["-d"]), ["-d"])
    }

    func testExpandArgsLongFlagPassthrough() {
        XCTAssertEqual(router.expandArgs(["--descriptors"]), ["--descriptors"])
    }

    func testExpandArgsMixedArray() {
        let args = ["-n", "Thingy", "-dr", "--read", "positional"]
        XCTAssertEqual(router.expandArgs(args), ["-n", "Thingy", "-d", "-r", "--read", "positional"])
    }

    func testExpandArgsEmpty() {
        XCTAssertEqual(router.expandArgs([]), [])
    }

    func testExpandArgsNonFlagPassthrough() {
        XCTAssertEqual(router.expandArgs(["tree", "2A19"]), ["tree", "2A19"])
    }

    func testExpandArgsValueAfterOptionNotExpanded() {
        // -70 following -R (a value-taking option) must pass through unchanged
        XCTAssertEqual(
            router.expandArgs(["-R", "-70"], optionsWithValue: ["-R"]),
            ["-R", "-70"]
        )
    }

    func testExpandArgsCombinedFlagFollowedByValue() {
        // -wR expands to [-w, -R]; then -70 is the value for -R and must not be expanded
        XCTAssertEqual(
            router.expandArgs(["-wR", "-70"], optionsWithValue: ["-R"]),
            ["-w", "-R", "-70"]
        )
    }

    func testExpandArgsValueLikeArgWithoutOptionSetIsExpanded() {
        // Without optionsWithValue, a dash-prefixed multi-char arg is still expanded
        // (documents default behaviour; callers must pass the set to prevent this)
        XCTAssertEqual(router.expandArgs(["-ab"]), ["-a", "-b"])
    }

    func testExpandArgsNegativeNumberSingleDigit() {
        // Single-char dash args are always passed through regardless of the set
        XCTAssertEqual(router.expandArgs(["-7"]), ["-7"])
    }

    // MARK: - Combined flags end-to-end (flag detection after expansion)

    func testContainsDetectsCombinedFlag() {
        let expanded = router.expandArgs(["-dr"])
        XCTAssertTrue(expanded.contains("-d"))
        XCTAssertTrue(expanded.contains("-r"))
    }

    func testContainsDoesNotFalsePositive() {
        let expanded = router.expandArgs(["-d"])
        XCTAssertTrue(expanded.contains("-d"))
        XCTAssertFalse(expanded.contains("-r"))
    }

    // MARK: - `--` and negative numbers

    func testNegativeNumberIsPositional() {
        XCTAssertEqual(router.positionalArgs(["-f", "float32le", "fff1", "-1.5"], optionsWithValue: ["-f"]),
                       ["fff1", "-1.5"])
        XCTAssertEqual(router.expandArgs(["-12"]), ["-12"])
        XCTAssertTrue(CommandRouter.scanOptions(["fff1", "-1.5"], optionsWithValue: []).isEmpty)
    }

    func testDoubleDashEndsOptions() {
        let args = ["-r", "--", "fff1", "-w", "-ab"]
        XCTAssertEqual(router.positionalArgs(args, optionsWithValue: []), ["fff1", "-w", "-ab"])
        XCTAssertEqual(CommandRouter.scanOptions(args, optionsWithValue: []).map(\.name), ["-r"])
        XCTAssertEqual(router.expandArgs(["-dr", "--", "-ab"]), ["-d", "-r", "--", "-ab"])
        XCTAssertFalse(router.hasFlag(args, short: "-w", long: "--without-response", optionsWithValue: []))
    }

    /// The value reaches the write; it fails only for want of a device.
    func testWriteTakesNegativeValue() {
        for args in [["-f", "float32le", "fff1", "-1.5"], ["-f", "float32le", "--", "fff1", "-1.5"]] {
            let result = router.runWrite(args)
            XCTAssertFalse(result.errors.contains { $0.contains("missing data") }, "\(args): \(result.errors)")
            XCTAssertTrue(result.errors.contains { $0.contains("not connected") }, "\(args): \(result.errors)")
        }
    }

    // MARK: - Option values are checked before connecting

    func testUnknownFormatIsRejected() {
        let results = [
            router.runRead(["-f", "bogus", "2a19"]),
            router.runWrite(["-f", "bogus", "fff1", "00"]),
            router.runSub(["-f", "bogus", "2a19"]),
            router.runPeriphSet(["-f", "bogus", "fff1", "00"]),
        ]
        for result in results {
            XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
            XCTAssertTrue(result.errors.contains { $0.contains("unknown format 'bogus'") }, "\(result.errors)")
        }
    }

    func testInvalidCountIsRejected() {
        for count in ["abc", "0", "-2"] {
            let result = router.runSub(["-c", count, "2a19"])
            XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
            XCTAssertTrue(result.errors.contains { $0.contains("invalid count '\(count)'") }, "\(result.errors)")
        }
    }

    /// An option without its value, or given twice, is an error before any
    /// connection, not an absent option (`periph clone -n X -o` must not
    /// clone without saving).
    func testOptionWithoutValueIsAnError() {
        let results = [
            router.runPeriphClone(["-n", "X", "-o"]),
            router.runRead(["2a19", "-f"]),
            router.runSub(["2a19", "-c"]),
            router.runSub(["2a19", "-d"]),
            router.runPeriphAdv(["-n"]),
        ]
        for result in results {
            XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
            XCTAssertTrue(result.errors.contains { $0.hasSuffix("needs a value") }, "\(result.errors)")
        }
        let twice = router.runSub(["2a19", "-c", "5", "-c", "abc"])
        XCTAssertEqual(twice.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(twice.errors, ["--count is given more than once"])
    }

    func testSaveReportsAFailedWrite() throws {
        let config = PeripheralConfig(name: "x", services: [])
        XCTAssertThrowsError(try CommandRouter.save(config, to: "/nonexistent-blew-dir/clone.json"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blew-save-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(CommandRouter.unwritableReason(url.path))
        try CommandRouter.save(config, to: url.path)
        XCTAssertEqual(try PeripheralConfig.load(from: url.path).name, "x")
        XCTAssertEqual(CommandRouter.unwritableReason(FileManager.default.temporaryDirectory.path), "it is a directory")
    }

    /// An unusable `--save` path fails before clone connects to anything.
    func testCloneChecksSavePathFirst() {
        let result = router.runPeriphClone(["--save", "/nonexistent-blew-dir/clone.json"])
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertTrue(result.errors.contains { $0.contains("cannot save to") }, "\(result.errors)")
    }
}

// MARK: - Helpers

private func makeGlobals() -> GlobalOptions {
    try! GlobalOptions.parse([])
}
