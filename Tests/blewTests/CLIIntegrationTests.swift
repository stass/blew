import XCTest
@testable import blew

/// End-to-end tests that launch the compiled `blew` binary and check output and exit codes.
/// These tests require the binary to be built; they are skipped if the binary is not found.
final class CLIIntegrationTests: XCTestCase {

    private var binaryPath: String { blewBinaryPath() ?? "" }

    private func blewAvailable() -> Bool {
        !binaryPath.isEmpty
    }

    // MARK: - --help

    func testHelpExitsZero() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["--help"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testHelpContainsAbstract() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["--help"])
        XCTAssertTrue(result.stdout.contains("BLE") || result.stderr.contains("BLE"),
                      "Help text should contain 'BLE'")
    }

    func testHelpListsSubcommands() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["--help"])
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("scan"))
        XCTAssertTrue(combined.contains("read"))
        XCTAssertTrue(combined.contains("write"))
        XCTAssertTrue(combined.contains("exec"))
    }

    // MARK: - --version

    func testVersionExitsZero() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["--version"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testVersionOutputNonEmpty() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["--version"])
        let combined = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(combined.isEmpty, "Version output should not be empty")
    }

    // MARK: - gatt info (no BLE required)

    func testGATTInfoBatteryLevelExitsZero() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["gatt", "info", "2A19"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testGATTInfoBatteryLevelOutputContainsName() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["gatt", "info", "2A19"])
        XCTAssertTrue(result.stdout.contains("Battery Level"),
                      "Output should contain 'Battery Level': \(result.stdout)")
    }

    func testGATTInfoBatteryLevelOutputContainsUUID() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["gatt", "info", "2A19"])
        XCTAssertTrue(result.stdout.contains("2A19"),
                      "Output should contain '2A19': \(result.stdout)")
    }

    func testGATTInfoBatteryLevelOutputContainsStructure() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["gatt", "info", "2A19"])
        XCTAssertTrue(result.stdout.contains("uint8") || result.stdout.contains("Structure"),
                      "Output should contain field info: \(result.stdout)")
    }

    func testGATTInfoHeartRateMeasurement() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["gatt", "info", "2A37"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Heart Rate"))
    }

    func testGATTInfoKVOutput() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["-o", "kv", "gatt", "info", "2A19"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("uuid=2A19"))
        XCTAssertTrue(result.stdout.contains("name="))
    }

    func testGATTInfoUnknownUUIDExitsNonZero() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["gatt", "info", "ZZZZ"])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    /// The README documents the exit codes; a subcommand must exit with them,
    /// not with ArgumentParser's generic 1.
    func testSubcommandExitsWithDocumentedCode() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        XCTAssertEqual(try runBlew(["gatt", "info", "ZZZZ"]).exitCode, BlewExitCode.notFound.code)
        let nus = try runBlew(["nus", "--pty", "--expect", "x"])
        XCTAssertEqual(nus.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertFalse(nus.stderr.contains("exit code"), nus.stderr)
    }

    func testGATTInfoUnknownUUIDPrintsError() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["gatt", "info", "ZZZZ"])
        XCTAssertTrue(result.stderr.contains("Error:"), "Should print 'Error:' to stderr: \(result.stderr)")
    }

    // MARK: - exec --dry-run (no BLE required)

    func testExecDryRunExitsZero() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["exec", "--dry-run", "help; gatt info 2A19"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testExecDryRunPrintsNumberedSteps() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["exec", "--dry-run", "help; gatt info 2A19"])
        XCTAssertTrue(result.stdout.contains("[1]"), "Should contain [1]: \(result.stdout)")
        XCTAssertTrue(result.stdout.contains("[2]"), "Should contain [2]: \(result.stdout)")
    }

    func testExecDryRunShowsCommands() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["exec", "--dry-run", "help; gatt info 2A19"])
        XCTAssertTrue(result.stdout.contains("help"))
        XCTAssertTrue(result.stdout.contains("gatt info 2A19"))
    }

    func testExecRunsRealCommands() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["exec", "gatt info 2A19"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("Battery Level"))
    }

    // MARK: - Invalid commands

    func testUnknownSubcommandExitsNonZero() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["bogussubcommand"])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testInvalidFlagExitsNonZero() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["--not-a-real-flag"])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    /// A usage error exits 6, the documented code, not ArgumentParser's 64,
    /// and still prints ArgumentParser's message and usage.
    func testUsageErrorExitsWithInvalidArguments() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        for args in [["--not-a-real-flag"], ["write", "fff1"], ["sub", "-c", "abc", "2a19"],
                     ["read", "-f", "bogus", "2a19"]] {
            let result = try runBlew(args)
            XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code, "\(args): \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("Usage:"), "\(args): \(result.stderr)")
        }
    }

    /// `exec` parses with the router: a bad option value is an error before
    /// any connection is tried.
    func testExecRejectsBadOptionValues() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let count = try runBlew(["exec", "sub -c abc 2a19"])
        XCTAssertEqual(count.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertTrue(count.stderr.contains("invalid count 'abc'"), count.stderr)
        let format = try runBlew(["exec", "read -f bogus 2a19"])
        XCTAssertEqual(format.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertTrue(format.stderr.contains("unknown format 'bogus'"), format.stderr)
    }

    /// A `;` inside quotes is part of the command, as the tokenizer reads it.
    func testExecKeepsQuotedSemicolon() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["exec", "--dry-run", "write -f utf8 fff1 'a;b'; write fff1 \"c;d\"; help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.split(separator: "\n"),
                       ["[1] write -f utf8 fff1 'a;b'", "[2] write fff1 \"c;d\"", "[3] help"])
    }

    /// After `--`, a value that starts with `-` reaches the write, which then
    /// fails only for want of a device.
    func testWriteTakesNegativeValueAfterDoubleDash() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["write", "-f", "float32le", "fff1", "--", "-1.5"])
        XCTAssertEqual(result.exitCode, BlewExitCode.invalidArguments.code)
        XCTAssertTrue(result.stderr.contains("not connected"), result.stderr)
    }

    // MARK: - Subcommand help

    func testScanHelpExitsZero() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["scan", "--help"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testReadHelpExitsZero() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["read", "--help"])
        XCTAssertEqual(result.exitCode, 0)
    }

    func testExecHelpExitsZero() throws {
        guard blewAvailable() else { throw XCTSkip("blew binary not built") }
        let result = try runBlew(["exec", "--help"])
        XCTAssertEqual(result.exitCode, 0)
    }
}

// MARK: - Process runner

private struct RunResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

private func runBlew(_ args: [String]) throws -> RunResult {
    guard let path = blewBinaryPath() else {
        throw XCTSkip("blew binary not found at .build/debug/blew")
    }
    return try launch(path: path, args: args)
}

/// The built `blew` binary: `.build/debug/blew` under the package root,
/// found by walking up from this source file; nil when it is not built.
func blewBinaryPath() -> String? {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url = url.deletingLastPathComponent()
        let candidate = url.appendingPathComponent(".build/debug/blew")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate.path
        }
    }
    return nil
}

private func launch(path: String, args: [String]) throws -> RunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    return RunResult(
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        exitCode: process.terminationStatus
    )
}
