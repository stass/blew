import XCTest
import Darwin

/// Launch the built `blew` binary, signal it mid-command, and check how it
/// exits. None of these commands touch a Bluetooth device: `gatt info`
/// reads the built-in tables and `sleep 0` waits until interrupted.
final class SignalIntegrationTests: XCTestCase {

    // MARK: - One-shot commands, stdout piped

    func testSIGINTInCLICommandExits130AfterFlushingOutput() throws {
        let child = try PipedBlew(["exec", "gatt info 2A19; sleep 0"])
        // Piped stdout reaches the reader while the command still runs.
        XCTAssertTrue(child.waitForStdout(containing: "Battery Level"),
                      "gatt info output did not arrive before the signal: \(child.stdout)")
        child.process.interrupt()
        let status = try child.waitForExit()
        XCTAssertEqual(status.reason, .exit, "blew died of the signal instead of exiting")
        XCTAssertEqual(status.code, 130)
    }

    func testSIGTERMInCLICommandExits143() throws {
        let child = try PipedBlew(["exec", "gatt info 2A19; sleep 0"])
        XCTAssertTrue(child.waitForStdout(containing: "Battery Level"),
                      "gatt info output did not arrive before the signal: \(child.stdout)")
        child.process.terminate()
        let status = try child.waitForExit()
        XCTAssertEqual(status.reason, .exit, "blew died of the signal instead of exiting")
        XCTAssertEqual(status.code, 143)
    }

    func testSIGINTStopsAKeepGoingScript() throws {
        let child = try PipedBlew(["-o", "kv", "exec", "-k", "gatt info 2A19; sleep 0; gatt info 2A37"])
        XCTAssertTrue(child.waitForStdout(containing: "2A19"),
                      "gatt info output did not arrive before the signal: \(child.stdout)")
        child.process.interrupt()
        let status = try child.waitForExit()
        XCTAssertEqual(status.reason, .exit)
        XCTAssertEqual(status.code, 130)
        XCTAssertTrue(child.waitForEOF())
        XCTAssertFalse(child.stdout.contains("2A37"), "the script went on after Ctrl-C: \(child.stdout)")
    }

    // MARK: - REPL on a terminal

    func testSIGTERMAtREPLPromptRestoresTerminalAndExits143() throws {
        let repl = try TerminalBlew()
        XCTAssertTrue(repl.waitForOutput(containing: "blew> "), "no prompt: \(repl.output)")
        XCTAssertFalse(repl.terminalIsCooked(), "the prompt should put the terminal in raw mode")
        repl.process.terminate()
        let status = try repl.waitForExit()
        XCTAssertEqual(status.reason, .exit, "blew died of the signal instead of exiting")
        XCTAssertEqual(status.code, 143)
        XCTAssertTrue(repl.terminalIsCooked(), "blew left the terminal in raw mode")
    }

    func testSIGINTAtREPLPromptRestoresTerminalAndExits130() throws {
        let repl = try TerminalBlew()
        XCTAssertTrue(repl.waitForOutput(containing: "blew> "), "no prompt: \(repl.output)")
        repl.process.interrupt()
        let status = try repl.waitForExit()
        XCTAssertEqual(status.reason, .exit, "blew died of the signal instead of exiting")
        XCTAssertEqual(status.code, 130)
        XCTAssertTrue(repl.terminalIsCooked(), "blew left the terminal in raw mode")
    }

    func testSIGINTDuringREPLCommandReturnsToPrompt() throws {
        let repl = try TerminalBlew()
        XCTAssertTrue(repl.waitForOutput(containing: "blew> "), "no prompt: \(repl.output)")
        XCTAssertEqual(repl.send("sleep 0\r"), 8)
        // The command runs with the terminal cooked again.
        XCTAssertTrue(repl.waitForOutput(containing: "sleep 0"), "sleep was not echoed: \(repl.output.debugDescription)")
        XCTAssertTrue(eventually { repl.terminalIsCooked() }, "sleep did not start: \(repl.output.debugDescription)")
        // The terminal is cooked a moment before the REPL opens the
        // command's span; a SIGINT in between would end the REPL.
        usleep(500_000)
        repl.process.interrupt()
        // A new prompt starts a line; LineNoise's redraws of the typed line
        // start with a bare "\r".
        XCTAssertTrue(repl.waitForOutput(containing: "\r\nblew> ", count: 2),
                      "no prompt after the interrupted command: \(repl.output)")
        XCTAssertTrue(repl.process.isRunning, "Ctrl-C during a command ended the REPL")
        repl.process.terminate()
        XCTAssertEqual(try repl.waitForExit().code, 143)
    }
}

// MARK: - Child processes

private struct ChildStillRunning: Error, CustomStringConvertible {
    var description: String { "blew did not exit after the signal; killed it" }
}

private struct ExitStatus {
    let reason: Process.TerminationReason
    let code: Int32
}

/// Wait up to `seconds` for `process` to exit; kill it and throw if it does not.
private func blewExit(_ process: Process, seconds: TimeInterval = 10) throws -> ExitStatus {
    let deadline = Date().addingTimeInterval(seconds)
    while process.isRunning && Date() < deadline {
        usleep(20_000)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        throw ChildStillRunning()
    }
    return ExitStatus(reason: process.terminationReason, code: process.terminationStatus)
}

/// Poll `condition` every 20 ms for up to `seconds`.
private func eventually(seconds: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        usleep(20_000)
    }
    return condition()
}

/// `blew` with stdout and stderr on pipes, collected as they arrive.
private final class PipedBlew {
    let process = Process()
    private let lock = NSLock()
    private var collected = Data()
    private var reachedEOF = false

    var stdout: String {
        lock.withLock { String(decoding: collected, as: UTF8.self) }
    }

    /// Wait until blew has closed stdout, so `stdout` is all it wrote.
    func waitForEOF() -> Bool {
        eventually { lock.withLock { reachedEOF } }
    }

    init(_ args: [String]) throws {
        guard let path = blewBinaryPath() else { throw XCTSkip("blew binary not built") }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self else { return }
            self.lock.withLock {
                if data.isEmpty { self.reachedEOF = true } else { self.collected.append(data) }
            }
        }
        try process.run()
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func waitForStdout(containing text: String) -> Bool {
        eventually { stdout.contains(text) }
    }

    func waitForExit() throws -> ExitStatus {
        try blewExit(process)
    }
}

/// `blew` with no arguments (the REPL) on a pseudo-terminal.
private final class TerminalBlew {
    let process = Process()
    private let master: Int32
    private let slave: Int32
    private var collected = Data()

    var output: String { String(decoding: collected, as: UTF8.self) }

    init() throws {
        guard let path = blewBinaryPath() else { throw XCTSkip("blew binary not built") }
        var m: Int32 = -1, s: Int32 = -1
        // A window size, so LineNoise does not query the cursor position.
        var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &size) == 0 else {
            throw XCTSkip("openpty failed: \(String(cString: strerror(errno)))")
        }
        master = m
        slave = s
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.executableURL = URL(fileURLWithPath: path)
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        try process.run()
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        close(master)
        close(slave)
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(master, &buffer, buffer.count)
            if n <= 0 { return }
            collected.append(contentsOf: buffer[0..<n])
        }
    }

    /// Type `text` at the terminal.
    func send(_ text: String) -> Int {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
    }

    /// Wait until `text` has appeared `count` times in the output.
    func waitForOutput(containing text: String, count: Int = 1) -> Bool {
        eventually { drain(); return output.components(separatedBy: text).count - 1 >= count }
    }

    /// Whether the terminal is in the line-editing mode a shell expects.
    func terminalIsCooked() -> Bool {
        var settings = termios()
        guard tcgetattr(slave, &settings) == 0 else { return false }
        let cooked = tcflag_t(ICANON | ECHO)
        return settings.c_lflag & cooked == cooked
    }

    func waitForExit() throws -> ExitStatus {
        defer { drain() }
        return try blewExit(process)
    }
}
