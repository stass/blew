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

    /// `exec -k "read ...; periph notify ..."` with the Ctrl-C landing as
    /// `read` fails: the failure keeps its code and the script stops there,
    /// so the `periph notify`, which has no wait, does not run.
    func testAStopEndsTheScriptAlsoWhenTheCommandFailed() {
        typealias Outcome = CommandRouter.ScriptCommandOutcome
        let timedOut = BlewExitCode.timeout.code
        XCTAssertTrue(Outcome(code: timedOut, stopRequested: true).endsScript(keepGoing: true))
        XCTAssertFalse(Outcome(code: timedOut, stopRequested: false).endsScript(keepGoing: true))
        XCTAssertTrue(Outcome(code: timedOut, stopRequested: false).endsScript(keepGoing: false))
        XCTAssertFalse(Outcome(code: BlewExitCode.success.code, stopRequested: false).endsScript(keepGoing: false))
    }

    /// A Ctrl-C between two `exec` commands (the outer span keeps it) keeps
    /// the next from starting.
    func testAStopBeforeAScriptCommandKeepsItFromRunning() throws {
        let signals = ProcessSignals()
        let router = CommandRouter(globals: try GlobalOptions.parse([]), signals: signals)
        signals.commandStarted()
        defer { signals.commandFinished() }
        signals.handle(.interrupt)
        XCTAssertEqual(router.runScriptCommand("bogus"),
                       CommandRouter.ScriptCommandOutcome(code: BlewExitCode.interrupted.code, stopRequested: true),
                       "bogus ran and failed with its own code")
    }

    /// SIGTERM during `exec "sleep 5; gatt info 2A19"`: the signal's exit
    /// stops the running wait, and the script ends there instead of running
    /// its next command beside the exit cleanup.
    func testASignalExitStopsTheRunningScriptCommand() throws {
        let signals = ProcessSignals()
        let router = CommandRouter(globals: try GlobalOptions.parse([]), signals: signals)
        let code = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        Thread.detachNewThread {
            let result = router.executeScript("sleep 5; gatt info 2A19")
            code.withLock { $0 = result }
        }
        usleep(200_000)
        _ = signals.beginSignalExit(BlewExitCode.terminated.code)
        let deadline = Date().addingTimeInterval(3)
        while code.withLock({ $0 }) == nil && Date() < deadline { usleep(20_000) }
        XCTAssertEqual(code.withLock { $0 }, BlewExitCode.interrupted.code,
                       "the script went on after the signal began the exit")
    }

    /// A script command with no wait (`periph notify`, here `gatt info`)
    /// does not start once a signal has begun the exit.
    func testNoScriptCommandStartsOnceASignalBeganTheExit() throws {
        let signals = ProcessSignals()
        let router = CommandRouter(globals: try GlobalOptions.parse([]), signals: signals)
        _ = signals.beginSignalExit(BlewExitCode.terminated.code)
        let returned = OSAllocatedUnfairLock(initialState: false)
        // Parks for good; the thread is left behind when the test ends.
        Thread.detachNewThread {
            _ = router.executeScript("gatt info 2A19")
            returned.withLock { $0 = true }
        }
        usleep(300_000)
        XCTAssertFalse(returned.withLock { $0 }, "a script command ran after the signal exit began")
    }
}

/// One owner ends the process. These use an instance of their own, since
/// a signal exit, once begun, parks every later command for good.
final class SignalExitOwnerTests: XCTestCase {

    /// A script line that arrives while a SIGINT's exit cleanup runs (a
    /// disconnect can take seconds) must not start its command.
    func testNoCommandStartsOnceASignalBeganTheExit() {
        let signals = ProcessSignals()
        XCTAssertTrue(signals.beginSignalExit(BlewExitCode.interrupted.code).runsCleanup,
                      "nothing else was exiting")
        let started = OSAllocatedUnfairLock(initialState: false)
        // Parks for good; the thread is left behind when the test ends.
        Thread.detachNewThread {
            signals.commandStarted()
            started.withLock { $0 = true }
        }
        usleep(300_000)
        XCTAssertFalse(started.withLock { $0 }, "a command started after the signal exit began")
    }

    /// The main thread that began its ordinary exit runs the cleanup and
    /// its code stands: a signal arriving during the cleanup ends the
    /// process at once with that code, without running the cleanup again.
    func testTheFirstToExitRunsTheCleanupAndKeepsItsCode() {
        let signals = ProcessSignals()
        signals.beginOrdinaryExit(with: BlewExitCode.success.code)
        XCTAssertEqual(signals.beginSignalExit(BlewExitCode.terminated.code),
                       ProcessSignals.SignalExit(code: BlewExitCode.success.code, runsCleanup: false))
        XCTAssertTrue(signals.stopRequested, "a command in flight would run beside the exit cleanup")
    }

    /// A signal that begins the exit as main returns from a one-shot
    /// command, `exec` or `blew mcp`: main's ordinary exit waits for the
    /// signal's, so the process ends with 143, not the command's 0, and every
    /// running command is asked to stop.
    func testASignalThatBeganTheExitKeepsItsCode() {
        let signals = ProcessSignals()
        XCTAssertEqual(signals.beginSignalExit(BlewExitCode.terminated.code),
                       ProcessSignals.SignalExit(code: BlewExitCode.terminated.code, runsCleanup: true))
        XCTAssertTrue(signals.stopRequested)
        let returned = OSAllocatedUnfairLock(initialState: false)
        // Parks for good; the thread is left behind when the test ends.
        Thread.detachNewThread {
            signals.beginOrdinaryExit(with: BlewExitCode.success.code)
            returned.withLock { $0 = true }
        }
        usleep(300_000)
        XCTAssertFalse(returned.withLock { $0 }, "main exited on its own after the signal began the exit")
    }
}

/// One rule for a stop that arrives as a command's last operation finishes,
/// for `blew write ...`, `exec "write ..."` and a piped REPL alike.
final class StopExitCodeTests: XCTestCase {
    func testAStopTurnsASuccessInto130AndKeepsAFailure() {
        let ok = BlewExitCode.success.code
        let interrupted = BlewExitCode.interrupted.code
        let timedOut = BlewExitCode.timeout.code
        XCTAssertEqual(SignalPolicy.exitCode(after: ok, stopRequested: false), ok)
        XCTAssertEqual(SignalPolicy.exitCode(after: ok, stopRequested: true), interrupted)
        XCTAssertEqual(SignalPolicy.exitCode(after: timedOut, stopRequested: true), timedOut)
    }
}
