import XCTest
import os
@testable import blew

/// One-shot CLI commands and `exec` have no span of their own: `main` opens
/// one around the whole command, so a Ctrl-C that one wait misses still
/// stops the command's next step.
final class CommandSpanTests: XCTestCase {

    func testMainOpensAnOuterSpanExceptForTheREPLAndMCP() throws {
        XCTAssertTrue(Blew.opensOuterSpan(for: try WriteCommand.parse(["fff1", "01"])))
        XCTAssertTrue(Blew.opensOuterSpan(for: try ExecCommand.parse(["status"])))
        XCTAssertFalse(Blew.opensOuterSpan(for: try Blew.parse([])))
        #if MCP_ENABLED
        XCTAssertFalse(Blew.opensOuterSpan(for: try MCPCommand.parse([])))
        #endif
    }

    /// The `write -n X` case: the Ctrl-C lands as auto-connect finishes, so
    /// that wait completes, and the write must then not start.
    func testACtrlCAtTheEndOfOneStepStopsTheNextStep() throws {
        let router = CommandRouter(globals: try GlobalOptions.parse([]))
        let signals = ProcessSignals.shared
        signals.commandStarted()
        defer { signals.commandFinished() }
        var writeRan = false
        let connect = router.waitInterruptible { signals.handle(.interrupt) }
        let write = router.waitInterruptible { writeRan = true }
        XCTAssertNotEqual(connect, .timedOut)
        XCTAssertEqual(write, .interrupted)
        XCTAssertFalse(writeRan, "the write started after Ctrl-C")
    }

    /// The `sleep 1; periph notify ...` case: the Ctrl-C lands as one
    /// command finishes, so that command succeeds, and the script must then
    /// stop before the next command, which may have no wait to see it. Here
    /// `gatt info` has no wait and `bogus` would fail with its own code.
    func testACtrlCAtTheEndOfOneScriptCommandStopsTheScript() throws {
        let router = CommandRouter(globals: try GlobalOptions.parse([]))
        let signals = ProcessSignals.shared
        signals.commandStarted()
        defer { signals.commandFinished() }
        signals.handle(.interrupt)
        XCTAssertEqual(router.executeScript("gatt info 2A19; bogus"), BlewExitCode.interrupted.code)
        XCTAssertEqual(router.executeScript("gatt info 2A19; bogus", keepGoing: true),
                       BlewExitCode.interrupted.code)
    }
}

/// One owner ends the process. These use an instance of their own, since
/// a signal exit, once begun, parks every later command for good.
final class SignalExitOwnerTests: XCTestCase {

    /// A script line that arrives while a SIGINT's exit cleanup runs (a
    /// disconnect can take seconds) must not start its command.
    func testNoCommandStartsOnceASignalBeganTheExit() {
        let signals = ProcessSignals()
        XCTAssertTrue(signals.beginSignalExit(), "nothing else was exiting")
        let started = OSAllocatedUnfairLock(initialState: false)
        // Parks for good; the thread is left behind when the test ends.
        Thread.detachNewThread {
            signals.commandStarted()
            started.withLock { $0 = true }
        }
        usleep(300_000)
        XCTAssertFalse(started.withLock { $0 }, "a command started after the signal exit began")
    }

    /// The main thread that began its ordinary exit runs the cleanup; a
    /// signal arriving after it does not run it a second time.
    func testTheFirstToExitRunsTheCleanup() {
        let signals = ProcessSignals()
        XCTAssertTrue(signals.beginOrdinaryExit())
        XCTAssertFalse(signals.beginOrdinaryExit(), "the cleanup ran twice")
        XCTAssertFalse(signals.beginSignalExit(), "the signal ran the cleanup the main thread is running")
    }
}
