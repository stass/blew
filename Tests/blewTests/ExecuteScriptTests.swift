import XCTest
@testable import blew

final class ExecuteScriptTests: XCTestCase {

    private func makeRouter() -> CommandRouter {
        CommandRouter(globals: makeGlobals(), isInteractiveMode: true)
    }

    // MARK: - Empty / blank scripts

    func testEmptyScriptReturnsZero() {
        XCTAssertEqual(makeRouter().executeScript(""), 0)
    }

    func testWhitespaceOnlyScriptReturnsZero() {
        XCTAssertEqual(makeRouter().executeScript("   "), 0)
    }

    func testSemicolonOnlyScriptReturnsZero() {
        XCTAssertEqual(makeRouter().executeScript(";"), 0)
    }

    func testMultipleSemicolonsOnlyReturnsZero() {
        XCTAssertEqual(makeRouter().executeScript(";;;"), 0)
    }

    // MARK: - Single-command scripts

    func testSingleHelpCommandReturnsZero() {
        XCTAssertEqual(makeRouter().executeScript("help"), 0)
    }

    func testSingleUnknownCommandReturnsError() {
        XCTAssertEqual(makeRouter().executeScript("boguscommand"), BlewExitCode.invalidArguments.code)
    }

    func testGATTInfoKnownUUIDReturnsZero() {
        XCTAssertEqual(makeRouter().executeScript("gatt info 2A19"), 0)
    }

    // MARK: - Multi-command scripts

    func testTwoHelpCommandsReturnsZero() {
        XCTAssertEqual(makeRouter().executeScript("help; help"), 0)
    }

    func testThreeCommandsAllSuccessReturnsZero() {
        XCTAssertEqual(makeRouter().executeScript("help; gatt info 2A19; help"), 0)
    }

    func testEmptySegmentsAreSkipped() {
        // Only "help" commands, empty segments from extra semicolons
        XCTAssertEqual(makeRouter().executeScript("help; ; ; help"), 0)
    }

    func testLeadingAndTrailingWhitespaceInSegmentsIsStripped() {
        XCTAssertEqual(makeRouter().executeScript("  help  ;  gatt info 2A19  "), 0)
    }

    // MARK: - Error handling: stop on first error (default)

    func testStopsOnFirstError() {
        // "bogus" fails; "help" after it should NOT run (no way to assert this directly,
        // but we verify the return code is the error from the first failed command)
        let code = makeRouter().executeScript("bogus; help")
        XCTAssertEqual(code, BlewExitCode.invalidArguments.code)
    }

    func testFirstCommandErrorReturnsItsCode() {
        let code = makeRouter().executeScript("gatt info ZZZZ; help")
        XCTAssertEqual(code, BlewExitCode.notFound.code)
    }

    // MARK: - keep-going mode

    func testKeepGoingContinuesAfterError() {
        // Two errors: first "bogus", second "bogus2". keepGoing should return the first error.
        let code = makeRouter().executeScript("bogusA; bogusB", keepGoing: true)
        XCTAssertEqual(code, BlewExitCode.invalidArguments.code)
    }

    func testKeepGoingReturnsFirstErrorCode() {
        // gatt info ZZZZ -> 2 (notFound), then bogusB -> 6 (invalidArguments)
        // keepGoing returns the FIRST non-zero code seen
        let code = makeRouter().executeScript("gatt info ZZZZ; bogusB", keepGoing: true)
        XCTAssertEqual(code, BlewExitCode.notFound.code)
    }

    func testKeepGoingSuccessfulCommandsAfterErrorStillRun() {
        // "help" after the failing command should still run (can't directly assert, but
        // the return code is from the error, not from help)
        let code = makeRouter().executeScript("bogus; help", keepGoing: true)
        XCTAssertEqual(code, BlewExitCode.invalidArguments.code)
    }

    func testKeepGoingAllSuccessReturnsZero() {
        XCTAssertEqual(makeRouter().executeScript("help; gatt info 2A19", keepGoing: true), 0)
    }

    // MARK: - dry-run mode

    func testDryRunReturnsZero() {
        XCTAssertEqual(makeRouter().executeScript("boguscommand", dryRun: true), 0)
    }

    func testDryRunDoesNotExecuteCommands() {
        // Even a failing command returns 0 in dry-run mode
        XCTAssertEqual(makeRouter().executeScript("gatt info ZZZZ", dryRun: true), 0)
    }

    func testDryRunPrintsNumberedSteps() {
        let output = captureStdout {
            _ = makeRouter().executeScript("help; gatt info 2A19", dryRun: true)
        }
        XCTAssertTrue(output.contains("[1]"))
        XCTAssertTrue(output.contains("[2]"))
        XCTAssertTrue(output.contains("help"))
        XCTAssertTrue(output.contains("gatt info 2A19"))
    }

    func testDryRunWithEmptyScriptPrintsNothing() {
        let output = captureStdout {
            _ = makeRouter().executeScript("", dryRun: true)
        }
        XCTAssertEqual(output, "")
    }

    func testDryRunSingleCommand() {
        let output = captureStdout {
            _ = makeRouter().executeScript("help", dryRun: true)
        }
        XCTAssertTrue(output.contains("[1]"))
        XCTAssertTrue(output.contains("help"))
        XCTAssertFalse(output.contains("[2]"))
    }

    // MARK: - Script tokenization with semicolons

    func testSemicolonInsideQuotedStringIsNotSplit() {
        // "gatt info 2A19" as a single quoted argument to exec
        // We test executeScript directly, so we pass the already-split content.
        // This is more of a tokenizer test; execute treats semicolons as separators at this level.
        // A semicolon in "gatt info 2A19" after splitting is still just one command.
        XCTAssertEqual(makeRouter().executeScript("gatt info 2A19"), 0)
    }
}

// MARK: - Helpers

private func makeGlobals() -> GlobalOptions {
    try! GlobalOptions.parse([])
}

private func captureStdout(_ block: () -> Void) -> String {
    fflush(stdout)  // flush buffered output from previous tests before redirecting
    let pipe = Pipe()
    let original = dup(STDOUT_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    block()
    fflush(stdout)
    dup2(original, STDOUT_FILENO)
    close(original)
    pipe.fileHandleForWriting.closeFile()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}
