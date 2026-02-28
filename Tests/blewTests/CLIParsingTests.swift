import XCTest
import ArgumentParser
@testable import blew

/// Tests that ArgumentParser correctly parses command-line arguments for each subcommand.
/// These tests use `parseAsRoot(_:)` which validates flags/options without running the command.
final class CLIParsingTests: XCTestCase {

    // MARK: - Top-level help / version

    func testHelpFlagParsesSuccessfully() {
        // --help may or may not throw depending on ArgumentParser version;
        // what matters is it does not throw a usage/validation error.
        XCTAssertNoThrow(try Blew.parseAsRoot(["--help"]))
    }

    func testVersionFlagThrows() {
        // --version throws a CommandError (not a usage error)
        XCTAssertThrowsError(try Blew.parseAsRoot(["--version"])) { error in
            // It should not be a clean success — it must be some form of error
            // (ArgumentParser wraps it in CommandError with versionRequested)
            XCTAssertFalse(error is CleanExit, "Version should not be a CleanExit")
        }
    }

    // MARK: - scan subcommand

    func testScanNoBehaviorParsesSuccessfully() throws {
        // We can't actually run scan (needs BLE), but parsing should succeed.
        // Just check that parseAsRoot doesn't throw a usage error.
        // Note: parseAsRoot succeeds if ArgumentParser can parse; it returns the command.
        _ = try Blew.parseAsRoot(["scan"])
    }

    func testScanWithWatchFlag() throws {
        _ = try Blew.parseAsRoot(["scan", "--watch"])
    }

    func testScanWithShortWatchFlag() throws {
        _ = try Blew.parseAsRoot(["scan", "-w"])
    }

    func testScanWithNameFilter() throws {
        _ = try Blew.parseAsRoot(["scan", "--name", "Thingy"])
    }

    func testScanWithShortNameFilter() throws {
        _ = try Blew.parseAsRoot(["scan", "-n", "Thingy"])
    }

    func testScanWithServiceFilter() throws {
        _ = try Blew.parseAsRoot(["scan", "-S", "180F"])
    }

    func testScanWithRSSIMin() throws {
        _ = try Blew.parseAsRoot(["scan", "--rssi-min", "-65"])
    }

    func testScanWithPickStrategy() throws {
        _ = try Blew.parseAsRoot(["scan", "--pick", "only"])
    }

    func testScanWithMultipleServiceFilters() throws {
        _ = try Blew.parseAsRoot(["scan", "-S", "180F", "-S", "180A"])
    }

    // MARK: - connect subcommand

    func testConnectByIDParsesSuccessfully() throws {
        _ = try Blew.parseAsRoot(["connect", "F3C2A1B0-1234-5678-ABCD-000000000001"])
    }

    func testConnectWithNameFilter() throws {
        _ = try Blew.parseAsRoot(["connect", "-n", "Thingy"])
    }

    func testConnectWithIDOption() throws {
        _ = try Blew.parseAsRoot(["connect", "--id", "F3C2A1B0-1234-5678-ABCD-000000000001"])
    }

    // MARK: - gatt subcommands

    func testGATTSvcs() throws {
        _ = try Blew.parseAsRoot(["gatt", "svcs", "-n", "Thingy"])
    }

    func testGATTTree() throws {
        _ = try Blew.parseAsRoot(["gatt", "tree", "-n", "Thingy"])
    }

    func testGATTTreeWithDescriptors() throws {
        _ = try Blew.parseAsRoot(["gatt", "tree", "--descriptors"])
    }

    func testGATTTreeWithRead() throws {
        _ = try Blew.parseAsRoot(["gatt", "tree", "--read"])
    }

    func testGATTChars() throws {
        _ = try Blew.parseAsRoot(["gatt", "chars", "-n", "Thingy", "180F"])
    }

    func testGATTDesc() throws {
        _ = try Blew.parseAsRoot(["gatt", "desc", "-n", "Thingy", "2A19"])
    }

    func testGATTInfo() throws {
        _ = try Blew.parseAsRoot(["gatt", "info", "2A19"])
    }

    func testGATTInfoShortForm() throws {
        _ = try Blew.parseAsRoot(["gatt", "info", "2A19"])
    }

    // MARK: - read subcommand

    func testReadWithFormatAndChar() throws {
        _ = try Blew.parseAsRoot(["read", "-f", "uint8", "2A19"])
    }

    func testReadWithLongFormat() throws {
        _ = try Blew.parseAsRoot(["read", "--format", "hex", "2A19"])
    }

    func testReadWithDeviceOptions() throws {
        _ = try Blew.parseAsRoot(["read", "-n", "Thingy", "-f", "utf8", "2A29"])
    }

    func testReadRequiresCharacteristic() {
        XCTAssertThrowsError(try Blew.parseAsRoot(["read"])) { error in
            XCTAssertFalse(error is CleanExit, "Should fail, not clean exit")
        }
    }

    // MARK: - write subcommand

    func testWriteWithFormatCharAndData() throws {
        _ = try Blew.parseAsRoot(["write", "-f", "hex", "2A19", "ff"])
    }

    func testWriteWithResponse() throws {
        _ = try Blew.parseAsRoot(["write", "-r", "fff1", "01"])
    }

    func testWriteWithoutResponse() throws {
        _ = try Blew.parseAsRoot(["write", "-w", "fff1", "01"])
    }

    func testWriteDefaultFormat() throws {
        _ = try Blew.parseAsRoot(["write", "fff1", "deadbeef"])
    }

    func testWriteRequiresCharAndData() {
        XCTAssertThrowsError(try Blew.parseAsRoot(["write"])) { _ in }
        XCTAssertThrowsError(try Blew.parseAsRoot(["write", "fff1"])) { _ in }
    }

    // MARK: - sub subcommand

    func testSubWithChar() throws {
        _ = try Blew.parseAsRoot(["sub", "fff1"])
    }

    func testSubWithDuration() throws {
        _ = try Blew.parseAsRoot(["sub", "-d", "30", "fff1"])
    }

    func testSubWithCount() throws {
        _ = try Blew.parseAsRoot(["sub", "-c", "10", "fff1"])
    }

    func testSubWithFormat() throws {
        _ = try Blew.parseAsRoot(["sub", "-f", "uint16le", "fff1"])
    }

    func testSubRequiresChar() {
        XCTAssertThrowsError(try Blew.parseAsRoot(["sub"])) { _ in }
    }

    // MARK: - exec subcommand

    func testExecWithScript() throws {
        _ = try Blew.parseAsRoot(["exec", "help"])
    }

    func testExecWithDryRun() throws {
        _ = try Blew.parseAsRoot(["exec", "--dry-run", "help; gatt info 2A19"])
    }

    func testExecWithKeepGoing() throws {
        _ = try Blew.parseAsRoot(["exec", "--keep-going", "read fff1"])
    }

    func testExecWithShortKeepGoing() throws {
        _ = try Blew.parseAsRoot(["exec", "-k", "help"])
    }

    func testExecRequiresScript() {
        XCTAssertThrowsError(try Blew.parseAsRoot(["exec"])) { _ in }
    }

    // MARK: - periph subcommands

    func testPeriphAdvWithService() throws {
        _ = try Blew.parseAsRoot(["periph", "adv", "-S", "180F"])
    }

    func testPeriphAdvWithName() throws {
        _ = try Blew.parseAsRoot(["periph", "adv", "-n", "MySensor", "-S", "180F"])
    }

    func testPeriphCloneWithName() throws {
        _ = try Blew.parseAsRoot(["periph", "clone", "-n", "Thingy"])
    }

    func testPeriphCloneWithSave() throws {
        _ = try Blew.parseAsRoot(["periph", "clone", "-n", "Thingy", "--save", "/tmp/out.json"])
    }

    // MARK: - Global options

    func testGlobalVerbosityShort() throws {
        _ = try Blew.parseAsRoot(["-v", "scan"])
    }

    func testGlobalVerbosityDouble() throws {
        _ = try Blew.parseAsRoot(["-vv", "scan"])
    }

    func testGlobalOutputFormatKV() throws {
        _ = try Blew.parseAsRoot(["-o", "kv", "scan"])
    }

    func testGlobalTimeout() throws {
        _ = try Blew.parseAsRoot(["-t", "10", "scan"])
    }

    func testGlobalOptionsBeforeSubcommand() throws {
        _ = try Blew.parseAsRoot(["-v", "-o", "kv", "-t", "5", "scan"])
    }

    // MARK: - Invalid subcommand

    func testInvalidSubcommandFails() {
        XCTAssertThrowsError(try Blew.parseAsRoot(["boguscommand"])) { error in
            XCTAssertFalse(error is CleanExit)
        }
    }

    func testInvalidGlobalOptionFails() {
        XCTAssertThrowsError(try Blew.parseAsRoot(["--not-a-flag", "scan"])) { error in
            XCTAssertFalse(error is CleanExit)
        }
    }

    func testInvalidOutputFormatFails() {
        XCTAssertThrowsError(try Blew.parseAsRoot(["-o", "json", "scan"])) { error in
            XCTAssertFalse(error is CleanExit)
        }
    }
}
