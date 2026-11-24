import XCTest
import LineNoise
@testable import blew

/// The REPL with a pipe as standard input: a script, run like `exec`.
/// Uses only commands that need no Bluetooth (`gatt info`, unknown commands).
final class REPLScriptTests: XCTestCase {

    private var openFDs: [Int32] = []
    private var historyDir: URL!

    override func setUpWithError() throws {
        historyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("blew-repl-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        for fd in openFDs { close(fd) }
        openFDs = []
        try? FileManager.default.removeItem(at: historyDir)
        super.tearDown()
    }

    private var historyPath: String {
        historyDir.appendingPathComponent("history").path
    }

    /// The read end of a pipe holding `input` followed by end of input.
    private func inputPipe(_ input: String) -> Int32 {
        return inputPipe(Array(input.utf8))
    }

    private func inputPipe(_ input: [UInt8]) -> Int32 {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        XCTAssertEqual(write(fds[1], input, input.count), input.count)
        close(fds[1])
        openFDs.append(fds[0])
        return fds[0]
    }

    /// What is left unread in a pipe.
    private func unread(_ fd: Int32) -> String {
        var rest: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while case let n = read(fd, &chunk, chunk.count), n > 0 {
            rest += chunk[0..<n]
        }
        return String(decoding: rest, as: UTF8.self)
    }

    private func repl(inputFile: Int32) -> REPL {
        let globals = try! GlobalOptions.parse([])
        return REPL(globals: globals, lineNoise: LineNoise(inputFile: inputFile),
                    historyPath: historyPath)
    }

    private func exitCode(of body: () throws -> Void) -> Int32? {
        do {
            try body()
            return nil
        } catch let code as BlewExitCode {
            return code.code
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    func testScriptRunsToEndOfInputAndLeavesTheHistoryAlone() throws {
        let input = inputPipe("gatt info 2A19\n\ngatt info 2A37")
        XCTAssertNil(exitCode { try repl(inputFile: input).run() })
        XCTAssertEqual(unread(input), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyDir.path))
    }

    func testFailingScriptCommandEndsTheRunWithItsCode() {
        let input = inputPipe("gatt info 2A19\nbogus\ngatt info 2A37\n")
        XCTAssertEqual(exitCode { try repl(inputFile: input).run() }, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(unread(input), "gatt info 2A37\n")
    }

    func testInvalidUTF8ScriptLineIsAnInvalidArgument() {
        let input = inputPipe([0x61, 0xC3, 0x28, 0x0A] + Array("gatt info 2A19\n".utf8))
        XCTAssertEqual(exitCode { try repl(inputFile: input).run() }, BlewExitCode.invalidArguments.code)
        XCTAssertEqual(unread(input), "gatt info 2A19\n")
    }

    func testUnreadableInputIsAnOperationFailure() {
        // read(2) on a directory fails with EISDIR.
        let dir = open("/", O_RDONLY)
        XCTAssertGreaterThanOrEqual(dir, 0)
        openFDs.append(dir)
        XCTAssertEqual(exitCode { try repl(inputFile: dir).run() }, BlewExitCode.operationFailed.code)
    }

    /// A Ctrl-C seen during a line of a script stops the script after that
    /// line, even when the line's own operation finished (here `gatt info`,
    /// which has no wait to see it).
    func testCtrlCStopsTheScriptAfterTheCurrentLine() {
        let fd = inputPipe("gatt info 2A19\ngatt info 2A19\n")
        let signals = ProcessSignals.shared
        // Stand in for the Ctrl-C arriving while the script runs: an open
        // span makes the signal a stop request rather than an exit.
        signals.commandStarted()
        defer { signals.commandFinished() }
        signals.handle(.interrupt)
        XCTAssertEqual(exitCode { try repl(inputFile: fd).run() }, BlewExitCode.interrupted.code)
        XCTAssertEqual(unread(fd), "gatt info 2A19\n", "the script went on after Ctrl-C")
    }
}
