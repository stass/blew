import XCTest
@testable import blew

/// The one option reader, `CommandSyntax.parse`, and the commands that use it.
final class CommandOptionsTests: XCTestCase {

    private var router: CommandRouter {
        CommandRouter(globals: try! GlobalOptions.parse([]))
    }

    private func parseError(_ syntax: CommandSyntax, _ args: [String]) -> String? {
        do {
            _ = try syntax.parse(args)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - The reader

    func testShortLongAndEqualsForms() throws {
        for args in [["-n", "My Device"], ["--name", "My Device"], ["--name=My Device"]] {
            XCTAssertEqual(try CommandSyntax.targeting.parse(args).value(.name), "My Device", "\(args)")
        }
        XCTAssertEqual(try CommandSyntax.targeting.parse(["--name="]).value(.name), "")
        XCTAssertNil(try CommandSyntax.targeting.parse([]).value(.name))
    }

    func testRepeatedOptionKeepsEveryValueInOrder() throws {
        let parsed = try CommandSyntax.targeting.parse(["-S", "180F", "--service", "180A", "--service=FFF0"])
        XCTAssertEqual(parsed.values(.service), ["180F", "180A", "FFF0"])
    }

    /// A missing value, a value given to a flag, a second value of a single
    /// option and an undeclared option are errors, never absent options.
    func testMalformedOptionsAreErrors() {
        XCTAssertEqual(parseError(.targeting, ["-n"]), "-n needs a value")
        XCTAssertEqual(parseError(.targeting, ["-S", "180F", "--service"]), "--service needs a value")
        XCTAssertEqual(parseError(.targeting, ["-n", "a", "--name", "b"]), "--name is given more than once")
        XCTAssertEqual(parseError(.scan, ["--watch=yes"]), "--watch takes no value")
        XCTAssertEqual(parseError(.targeting, ["-x"]), "unknown option '-x'")
        XCTAssertEqual(parseError(.targeting, ["--bogus=1"]), "unknown option '--bogus'")
        XCTAssertEqual(parseError(.read, ["-d"]), "unknown option '-d'")
    }

    /// An option that takes a value takes the next token, whatever it looks
    /// like, so a value is never read as an option.
    func testValueOptionTakesTheNextTokenWhatever() throws {
        let parsed = try CommandSyntax.sub.parse(["-n", "-b", "-S", "-S", "-R", "-70", "2A19"])
        XCTAssertEqual(parsed.value(.name), "-b")
        XCTAssertFalse(parsed.flag(.background))
        XCTAssertEqual(parsed.values(.service), ["-S"])
        XCTAssertEqual(parsed.value(.rssiMin), "-70")
        XCTAssertEqual(parsed.positionals, ["2A19"])
        XCTAssertEqual(try CommandSyntax.connect.parse(["-n", "--", "x"]).value(.name), "--")
    }

    func testShortFlagsCombineAndAValueOptionEndsTheGroup() throws {
        let tree = try CommandSyntax.gattSubcommands["tree"]!.parse(["tree", "-dr"])
        XCTAssertTrue(tree.flag(.descriptors))
        XCTAssertTrue(tree.flag(.readValues))
        let scan = try CommandSyntax.scan.parse(["-wR", "-70"])
        XCTAssertTrue(scan.flag(.watch))
        XCTAssertEqual(scan.value(.rssiMin), "-70")
        XCTAssertEqual(parseError(.scan, ["-Rw", "-70"]), "-R takes a value, so it must end '-Rw'")
        XCTAssertEqual(parseError(.gatt, ["-dx"]), "unknown option '-x'")
    }

    func testNumbersBareDashAndEndOfOptionsArePositionals() throws {
        let write = try CommandSyntax.write.parse(["-f", "float32le", "-", "-1.5"])
        XCTAssertEqual(write.positionals, ["-", "-1.5"])
        XCTAssertEqual(write.value(.format), "float32le")
        XCTAssertEqual(try CommandSyntax.write.parse(["-7", "-f", "uint8", "-"]).positionals, ["-7", "-"])
        let ended = try CommandSyntax.write.parse(["-r", "--", "-w", "--"])
        XCTAssertTrue(ended.flag(.withResponse))
        XCTAssertFalse(ended.flag(.withoutResponse))
        XCTAssertEqual(ended.positionals, ["-w", "--"])
        XCTAssertEqual(parseError(.write, ["--", "fff1", "-ab", "--"]),
                       "unexpected argument '--' -- usage: write [options] <char> <data>")
    }

    // MARK: - Commands

    /// A repeatable option without its value is an error, not an absent
    /// option: `periph adv -c cfg.json -S` must not advertise the config's
    /// services as if `-S` were not there.
    func testPeriphAdvServiceWithoutValueIsAnError() {
        // A config path that does not exist: the unfixed reader drops `-S`
        // and fails on loading the file, so nothing ever advertises here.
        let config = "/nonexistent-blew-dir/cfg.json"
        for args in [["-c", config, "-S"], ["-c", config, "--service"]] {
            let result = router.runPeriphAdv(args)
            XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code, "\(args)")
            XCTAssertTrue(result.errors.contains { $0.hasSuffix("needs a value") }, "\(args): \(result.errors)")
        }
    }

    /// `-b` after `-p` is the value of `-p`, not the background flag, and
    /// `2A19` stays the characteristic. (`-p` fails on its value before any
    /// scan; `sub -n -b 2A19` reads `-b` the same way.)
    func testFlagSpellingAfterAValueOptionIsTheValue() {
        let result = router.runSub(["-p", "-b", "2A19"])
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertFalse(result.errors.contains { $0.contains("missing <char>") }, "\(result.errors)")
        XCTAssertTrue(result.errors.contains { $0.contains("'-b'") }, "\(result.errors)")
    }

    /// The MCP server's `sub` has no `-b`, so no argument can start a
    /// background subscription.
    func testForegroundSubHasNoBackgroundFlag() {
        let result = router.runSub(["-b", "2A19"], foregroundOnly: true)
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(result.errors, ["unknown option '-b'"])
    }

    /// An option a command does not take fails before anything connects,
    /// and each `gatt` subcommand takes only its own options.
    func testUnknownOptionsFailBeforeConnecting() {
        let results = [
            router.runRead(["-x", "2a19"]),
            router.runWrite(["--bogus", "fff1", "00"]),
            router.runGATT(["svcs", "-d"]),
            router.runGATT(["chars", "-d", "180F"]),
            router.runGATT(["info", "-n", "x", "2A19"]),
            router.runDisconnect(["-i"]),
            router.runPeriphSet(["-r", "fff1", "00"]),
        ]
        for result in results {
            XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
            XCTAssertTrue(result.errors.first?.hasPrefix("unknown option") == true, "\(result.errors)")
        }
    }

    /// Options may come before the gatt subcommand.
    func testGATTSubcommandAfterOptions() {
        let result = router.runGATT(["-p", "bogus", "tree"])
        XCTAssertEqual(result.errors, ["invalid pick strategy 'bogus' (use strongest, first or only)"])
        let unknown = router.runGATT(["-n", "x", "nope"])
        XCTAssertEqual(unknown.errors, ["unknown gatt subcommand 'nope'"])
        XCTAssertEqual(unknown.exitCode, BlewExitCode.invalidArguments.code)
    }

    func testConnectTakesOneDeviceOrTargetingOptions() {
        let both = router.runConnect(["-n", "x", "ABCD"])
        XCTAssertEqual(both.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(both.errors, ["name the device as an argument or with targeting options, not both"])
        let two = router.runConnect(["ABCD", "EF01"])
        XCTAssertEqual(two.errors, ["unexpected argument 'EF01' -- usage: connect [options] [<id>]"])
    }

    /// The value reaches the write; it fails only for want of a device.
    func testWriteTakesNegativeValue() {
        for args in [["-f", "float32le", "fff1", "-1.5"], ["-f", "float32le", "--", "fff1", "-1.5"]] {
            let result = router.runWrite(args)
            XCTAssertFalse(result.errors.contains { $0.contains("missing <data>") }, "\(args): \(result.errors)")
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

    // MARK: - Positionals

    private func assertFails(_ result: CommandResult, _ prefix: String, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code, "\(label): \(result.errors)",
                       file: file, line: line)
        XCTAssertTrue(result.errors.count == 1 && result.errors[0].hasPrefix(prefix) && result.errors[0].contains(" -- usage: "),
                      "\(label): \(result.errors)", file: file, line: line)
    }

    /// The reader rejects too many and too few positionals and names the
    /// command's usage, derived from its declared positionals.
    func testParseChecksPositionalCount() {
        XCTAssertEqual(parseError(.write, ["fff1", "01", "02"]),
                       "unexpected argument '02' -- usage: write [options] <char> <data>")
        XCTAssertEqual(parseError(.write, ["fff1"]), "missing <data> -- usage: write [options] <char> <data>")
        XCTAssertEqual(parseError(.write, []), "missing <char> -- usage: write [options] <char> <data>")
        XCTAssertEqual(parseError(.connect, ["a", "b"]), "unexpected argument 'b' -- usage: connect [options] [<id>]")
        XCTAssertEqual(parseError(.disconnect, ["x"]), "unexpected argument 'x' -- usage: disconnect")
        XCTAssertEqual(parseError(CommandSyntax.gattSubcommands["chars"]!, ["chars"]),
                       "missing <service> -- usage: gatt chars [options] <service>")
        XCTAssertEqual(parseError(CommandSyntax.gattSubcommands["info"]!, ["info", "2A19", "x"]),
                       "unexpected argument 'x' -- usage: gatt info <char>")
        XCTAssertEqual(try CommandSyntax.write.parse(["-r", "fff1", "--", "-1"]).positionals, ["fff1", "-1"])
        XCTAssertEqual(try CommandSyntax.connect.parse([]).positionals, [])
    }

    /// An extra positional fails with exit 6 before anything connects:
    /// `write fff1 01 02` does not write `01`.
    func testExtraPositionalFailsBeforeConnecting() {
        let cases: [(String, CommandResult)] = [
            ("read", router.runRead(["2a19", "x"])),
            ("write", router.runWrite(["fff1", "01", "02"])),
            ("sub", router.runSub(["2a19", "x"])),
            ("sub mcp", router.runSub(["--", "2a19", "x"], foregroundOnly: true)),
            ("gatt svcs", router.runGATT(["svcs", "x"])),
            ("gatt tree", router.runGATT(["-d", "tree", "x"])),
            ("gatt chars", router.runGATT(["chars", "180F", "x"])),
            ("gatt desc", router.runGATT(["desc", "2A19", "x"])),
            ("gatt info", router.runGATT(["info", "2A19", "x"])),
            ("periph set", router.runPeriphSet(["fff1", "00", "01"])),
            ("periph notify", router.runPeriphNotify(["fff1", "00", "01"])),
        ]
        for (label, result) in cases {
            assertFails(result, "unexpected argument '", label)
        }
    }

    /// A `gatt` subcommand's errors name its own usage, however many extra
    /// arguments follow it; without a subcommand, `gatt` shows its usage.
    func testGATTPositionalErrorsNameTheSubcommandUsage() {
        XCTAssertEqual(router.runGATT(["info", "2A19", "x", "y"]).errors,
                       ["unexpected argument 'x' -- usage: gatt info <char>"])
        XCTAssertEqual(router.runGATT(["-n", "d", "chars", "180F", "x"]).errors,
                       ["unexpected argument 'x' -- usage: gatt chars [options] <service>"])
        XCTAssertEqual(router.runGATT(["desc"]).errors, ["missing <char> -- usage: gatt desc [options] <char>"])
        XCTAssertEqual(router.runGATT(["nope", "a", "b"]).errors, ["unknown gatt subcommand 'nope'"])
        let missing = router.runGATT(["-n", "x"])
        XCTAssertEqual(missing.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(missing.errors, ["missing subcommand"])
        guard missing.output.count == 1, case .message(let usage) = missing.output[0] else {
            return XCTFail("\(missing.output)")
        }
        XCTAssertEqual(usage, "Usage: gatt <svcs|tree|chars|desc|info>")
    }

    /// `scan` takes no positional: `scan Thingy` does not scan everything.
    func testScanRejectsPositional() {
        assertFails(router.runScan(["Thingy"]), "unexpected argument 'Thingy'", "scan")
        assertFails(router.runScan(["-w", "Thingy"]), "unexpected argument 'Thingy'", "scan -w")
    }

    /// A missing required positional fails with exit 6 and names it.
    func testMissingPositionalFails() {
        let cases: [(String, CommandResult)] = [
            ("read", router.runRead([])),
            ("write", router.runWrite(["fff1"])),
            ("sub", router.runSub(["-c", "1"])),
            ("gatt chars", router.runGATT(["chars"])),
            ("gatt desc", router.runGATT(["desc"])),
            ("gatt info", router.runGATT(["info"])),
            ("periph set", router.runPeriphSet(["fff1"])),
            ("sleep", router.runSleep([])),
        ]
        for (label, result) in cases {
            assertFails(result, "missing <", label)
        }
    }

    /// `periph adv -t` bounds the wait for advertising to start, the way
    /// `scan -t` bounds a scan: its own value, else the global `-t`, else
    /// 15 seconds.
    func testPeriphAdvTimeoutBoundsTheStartWait() throws {
        let local = try CommandSyntax.periphAdv.parse(["-t", "0.5", "-S", "180F"])
        XCTAssertEqual(try router.advertisingStartTimeout(local), 0.5)
        let withGlobal = CommandRouter(globals: try GlobalOptions.parse(["-t", "3"]))
        XCTAssertEqual(try withGlobal.advertisingStartTimeout(local), 0.5)
        let none = try CommandSyntax.periphAdv.parse(["-S", "180F"])
        XCTAssertEqual(try withGlobal.advertisingStartTimeout(none), 3)
        XCTAssertEqual(try router.advertisingStartTimeout(none), 15)
    }

    /// An invalid `periph adv -t` fails before anything advertises.
    func testPeriphAdvRejectsAnInvalidTimeout() {
        for value in ["soon", "inf", "nan", "-1", "1e30"] {
            let result = router.runPeriphAdv(["-t", value, "-S", "180F"])
            XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code, value)
            XCTAssertEqual(result.errors.count, 1, value)
            XCTAssertTrue(result.errors.first?.hasPrefix("invalid timeout '\(value)'") == true, "\(value): \(result.errors)")
        }
    }

    /// The commands that take no positional, or at most one, reject more.
    func testCommandsWithFewPositionalsRejectMore() {
        let cases: [(String, CommandResult)] = [
            ("connect", router.runConnect(["ABCD", "EF01"])),
            ("disconnect", router.runDisconnect(["x"])),
            ("status", router.runStatus(["x"])),
            ("sleep", router.runSleep(["1", "x"])),
            ("sub stop", router.runSubStop(["2a19", "x"])),
            ("sub status", router.runSubStatus(["x"])),
            ("periph adv", router.runPeriphAdv(["x"])),
            ("periph clone", router.runPeriphClone(["x"])),
            ("periph stop", router.runPeriphStop(["x"])),
            ("periph status", router.runPeriphStatus(["x"])),
        ]
        for (label, result) in cases {
            assertFails(result, "unexpected argument '", label)
        }
        XCTAssertThrowsError(try CommandRouter.parseNUSOptions(["x"], stdinAvailable: false)) { error in
            XCTAssertEqual(error.localizedDescription, "unexpected argument 'x' -- usage: nus [options]")
        }
    }
}
