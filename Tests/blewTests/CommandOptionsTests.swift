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
        XCTAssertEqual(try CommandSyntax.targeting.parse(["-n", "--", "x"]).value(.name), "--")
    }

    func testShortFlagsCombineAndAValueOptionEndsTheGroup() throws {
        let tree = try CommandSyntax.gatt.parse(["tree", "-dr"])
        XCTAssertTrue(tree.flag(.descriptors))
        XCTAssertTrue(tree.flag(.readValues))
        let scan = try CommandSyntax.scan.parse(["-wR", "-70"])
        XCTAssertTrue(scan.flag(.watch))
        XCTAssertEqual(scan.value(.rssiMin), "-70")
        XCTAssertEqual(parseError(.scan, ["-Rw", "-70"]), "-R takes a value, so it must end '-Rw'")
        XCTAssertEqual(parseError(.gatt, ["-dx"]), "unknown option '-x'")
    }

    func testNumbersBareDashAndEndOfOptionsArePositionals() throws {
        let write = try CommandSyntax.write.parse(["-f", "float32le", "fff1", "-1.5", "-", "-7"])
        XCTAssertEqual(write.positionals, ["fff1", "-1.5", "-", "-7"])
        XCTAssertEqual(write.value(.format), "float32le")
        let ended = try CommandSyntax.write.parse(["-r", "--", "fff1", "-w", "-ab", "--"])
        XCTAssertTrue(ended.flag(.withResponse))
        XCTAssertFalse(ended.flag(.withoutResponse))
        XCTAssertEqual(ended.positionals, ["fff1", "-w", "-ab", "--"])
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
        XCTAssertFalse(result.errors.contains { $0.contains("missing characteristic UUID") }, "\(result.errors)")
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
        XCTAssertEqual(two.errors, ["unexpected argument 'EF01'"])
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
