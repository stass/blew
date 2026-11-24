import XCTest
@testable import LineNoise

/// The line editor driven through pipes: bytes written to the input pipe are
/// what a terminal would send, and the output pipe collects what the editor
/// draws. A pipe is not a TTY, so `getLine` takes the non-TTY path, while
/// `editLine` runs the raw-mode key handling directly.
final class LineNoiseTests: XCTestCase {

    private var openFDs: [Int32] = []

    override func tearDown() {
        for fd in openFDs { close(fd) }
        openFDs = []
        super.tearDown()
    }

    /// A pipe holding `bytes` followed by end of input; returns its read end.
    private func inputPipe(_ bytes: [UInt8]) -> Int32 {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        XCTAssertEqual(write(fds[1], bytes, bytes.count), bytes.count)
        close(fds[1])
        openFDs.append(fds[0])
        return fds[0]
    }

    /// An empty pipe; returns (read end, write end).
    private func outputPipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        openFDs.append(fds[0])
        openFDs.append(fds[1])
        return (fds[0], fds[1])
    }

    /// Everything written to the output pipe so far. Closes its write end.
    private func drain(_ out: (read: Int32, write: Int32)) -> [UInt8] {
        close(out.write)
        openFDs.removeAll { $0 == out.write }
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(out.read, &chunk, chunk.count)
            if n <= 0 { break }
            result += chunk[0..<n]
        }
        return result
    }

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    private let ctrlA: [UInt8] = [0x01]
    private let ctrlB: [UInt8] = [0x02]
    private let ctrlD: [UInt8] = [0x04]
    private let ctrlT: [UInt8] = [0x14]
    private let enter: [UInt8] = [0x0D]
    private let backspace: [UInt8] = [0x7F]
    private let right: [UInt8] = [0x1B, 0x5B, 0x43]
    private let delete: [UInt8] = [0x1B, 0x5B, 0x33, 0x7E]

    /// Runs the raw-mode editor over `keys` and returns the line it produced.
    private func edit(_ keys: [UInt8]) throws -> String {
        let out = outputPipe()
        let ln = LineNoise(inputFile: inputPipe(keys), outputFile: out.write)
        return try ln.editLine(prompt: "> ")
    }

    // MARK: - UTF-8 input in the raw-mode editor

    func testTypedMultibyteCharacterIsDecodedAsUTF8() throws {
        XCTAssertEqual(try edit(bytes("é") + enter), "é")
        XCTAssertEqual(try edit(bytes("a€😀b") + enter), "a€😀b")
    }

    /// A line typed while the terminal was cooked reaches the editor with
    /// its CR already turned into LF (ICRNL), so LF ends a line as Enter does.
    func testLineFeedEndsTheLine() throws {
        XCTAssertEqual(try edit(bytes("ab\n")), "ab")
    }

    func testCombiningMarkJoinsThePreviousCharacter() throws {
        // "e" then U+0301 COMBINING ACUTE ACCENT, then Ctrl-B and "x":
        // the cursor steps over the whole "é", not into it.
        XCTAssertEqual(try edit(bytes("e\u{301}") + ctrlB + bytes("x") + enter), "xe\u{301}")
    }

    func testInvalidUTF8IsDroppedAndTheByteThatEndedItIsKept() throws {
        // A lead byte followed by "(" is not UTF-8: the lead byte is dropped
        // and "(" is still typed. A stray continuation byte is dropped.
        XCTAssertEqual(try edit([0xC3] + bytes("(") + [0xA9] + bytes("ok") + enter), "(ok")
        // A lead byte followed by Enter still ends the line.
        XCTAssertEqual(try edit(bytes("a") + [0xE2, 0x82] + enter), "a")
    }

    func testEndOfInputInsideTheEditorIsEOF() {
        XCTAssertThrowsError(try edit(bytes("ab"))) { error in
            guard case LinenoiseError.EOF = error else {
                return XCTFail("expected EOF, got \(error)")
            }
        }
        XCTAssertThrowsError(try edit(bytes("a") + [0xC3])) { error in
            guard case LinenoiseError.EOF = error else {
                return XCTFail("expected EOF, got \(error)")
            }
        }
    }

    // MARK: - Editing around multibyte characters

    func testCtrlTSwapsMultibyteCharacters() throws {
        // At the end of the line: swap the last two.
        XCTAssertEqual(try edit(bytes("aé") + ctrlT + enter), "éa")
        // In the middle: swap with the previous one and step right.
        XCTAssertEqual(try edit(bytes("aéb") + ctrlB + ctrlT + bytes("x") + enter), "abéx")
        XCTAssertEqual(try edit(bytes("aé") + ctrlB + ctrlT + bytes("x") + enter), "éax")
        // At the start: swap the first two and put the cursor after them.
        XCTAssertEqual(try edit(bytes("éa€") + ctrlA + ctrlT + bytes("x") + enter), "aéx€")
    }

    func testBackspaceAfterMultibyteCharacterKeepsTheCursorValid() throws {
        XCTAssertEqual(try edit(bytes("aéb") + ctrlB + backspace + bytes("c") + enter), "acb")
        XCTAssertEqual(try edit(bytes("é€") + backspace + backspace + bytes("x") + enter), "x")
    }

    func testDeleteAtMultibyteCharacterKeepsTheCursorValid() throws {
        XCTAssertEqual(try edit(bytes("aéb") + ctrlA + right + delete + bytes("c") + enter), "acb")
        XCTAssertEqual(try edit(bytes("aéb") + ctrlA + right + ctrlD + bytes("c") + enter), "acb")
    }

    // MARK: - Output

    func testOutputWritesEveryUTF8Byte() throws {
        let out = outputPipe()
        let ln = LineNoise(inputFile: inputPipe([]), outputFile: out.write)
        let text = "é€😀\u{1B}[0K"
        try ln.output(text: text)
        try ln.output(character: "é")
        XCTAssertEqual(drain(out), bytes(text + "é"))
    }

    func testEditorEchoesTypedCharactersAsUTF8() throws {
        let out = outputPipe()
        let ln = LineNoise(inputFile: inputPipe(bytes("é€") + enter), outputFile: out.write)
        XCTAssertEqual(try ln.editLine(prompt: "> "), "é€")
        let drawn = String(decoding: drain(out), as: UTF8.self)
        XCTAssertTrue(drawn.hasSuffix("\r> é€\u{1B}[0K\r\u{1B}[4C"), "drawn: \(drawn.debugDescription)")
    }

    func testRawModeLineEndsWithANewline() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        openFDs.append(slave)
        // The thread plays the terminal. It types once canonical mode is
        // off, then reads what the editor draws until the line ends with
        // CR LF, or for 5 seconds. It closes the master when done, so an editor still waiting then gets
        // an error instead of hanging the suite.
        var drawn: [UInt8] = []
        let finished = DispatchSemaphore(value: 0)
        let terminal = Thread { [master] in
            defer {
                close(master)
                finished.signal()
            }
            let deadline = Date().addingTimeInterval(5)
            var mode = termios()
            while Date() < deadline {
                if tcgetattr(master, &mode) == 0 && mode.c_lflag & UInt(ICANON) == 0 { break }
                usleep(1000)
            }
            let keys: [UInt8] = Array("ab\r".utf8)
            _ = write(master, keys, keys.count)
            _ = fcntl(master, F_SETFL, O_NONBLOCK)
            var chunk = [UInt8](repeating: 0, count: 4096)
            while Date() < deadline && drawn.suffix(2) != [0x0D, 0x0A] {
                let n = read(master, &chunk, chunk.count)
                if n > 0 { drawn += chunk[0..<n] } else { usleep(1000) }
            }
        }
        terminal.start()
        let ln = LineNoise(inputFile: slave, outputFile: slave)
        XCTAssertEqual(try ln.getLineRaw(prompt: "> "), "ab")
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        // Cooked mode is back, so the newline reaches the terminal as CR LF.
        XCTAssertEqual(Array(drawn.suffix(2)), [0x0D, 0x0A], "drawn: \(drawn)")
    }

    // MARK: - Non-TTY input

    func testNonTTYInputReadsLinesThenReportsEOF() throws {
        let ln = LineNoise(inputFile: inputPipe(bytes("status\nread é\r\n\nlast")),
                           outputFile: outputPipe().write)
        XCTAssertEqual(ln.mode, .notATTY)
        XCTAssertEqual(try ln.getLine(prompt: "> "), "status")
        XCTAssertEqual(try ln.getLine(prompt: "> "), "read é")
        XCTAssertEqual(try ln.getLine(prompt: "> "), "")
        XCTAssertEqual(try ln.getLine(prompt: "> "), "last")
        XCTAssertThrowsError(try ln.getLine(prompt: "> ")) { error in
            guard case LinenoiseError.EOF = error else {
                return XCTFail("expected EOF, got \(error)")
            }
        }
    }

    func testNonTTYEmptyInputIsEOF() {
        let ln = LineNoise(inputFile: inputPipe([]), outputFile: outputPipe().write)
        XCTAssertThrowsError(try ln.getLine(prompt: "> ")) { error in
            guard case LinenoiseError.EOF = error else {
                return XCTFail("expected EOF, got \(error)")
            }
        }
    }

    func testNonTTYInvalidUTF8LineIsAnErrorAndReadingContinues() throws {
        let ln = LineNoise(inputFile: inputPipe([0x61, 0xC3, 0x28, 0x0A] + bytes("ok\n")),
                           outputFile: outputPipe().write)
        XCTAssertThrowsError(try ln.getLine(prompt: "> ")) { error in
            guard case LinenoiseError.invalidUTF8 = error else {
                return XCTFail("expected invalidUTF8, got \(error)")
            }
        }
        XCTAssertEqual(try ln.getLine(prompt: "> "), "ok")
    }

    // MARK: - UTF-8 sequence assembly

    /// Runs `readSequence` over `bytes` and reports how many it read.
    private func readSequence(_ bytes: [UInt8]) -> (UTF8Input.Decoded, read: Int) {
        var rest = bytes.dropFirst()[...]
        let sequence = UTF8Input.readSequence(lead: bytes[0]) { rest.popFirst() }
        return (sequence, bytes.count - 1 - rest.count)
    }

    func testReadSequenceReadsOnlyItsOwnBytes() {
        let (euro, read) = readSequence([0xE2, 0x82, 0xAC, 0x41])
        XCTAssertEqual(euro, UTF8Input.Decoded(scalar: "€", unconsumed: nil))
        XCTAssertEqual(read, 2)
    }

    func testReadSequenceRejectsInvalidEncodings() {
        let invalid: [[UInt8]] = [
            [0x80],                     // continuation byte as lead
            [0xC0, 0x80],               // overlong NUL
            [0xE0, 0x80, 0x80],         // overlong 3-byte
            [0xED, 0xA0, 0x80],         // UTF-16 surrogate
            [0xF4, 0x90, 0x80, 0x80],   // above U+10FFFF
            [0xF5, 0x80, 0x80, 0x80],   // lead byte that is never valid
            [0xE2, 0x82],               // end of input inside a sequence
        ]
        for bytes in invalid {
            XCTAssertNil(readSequence(bytes).0.scalar, "\(bytes)")
        }
    }

    func testReadSequenceHandsBackTheByteThatEndedIt() {
        let (sequence, _) = readSequence([0xE2, 0x82, 0x0D])
        XCTAssertEqual(sequence, UTF8Input.Decoded(scalar: nil, unconsumed: 0x0D))
    }

    func testReadErrorIsAnErrorNotANulByte() throws {
        // read(2) on a directory fails with EISDIR.
        let dir = open("/", O_RDONLY)
        XCTAssertGreaterThanOrEqual(dir, 0)
        openFDs.append(dir)
        let ln = LineNoise(inputFile: dir, outputFile: outputPipe().write)
        XCTAssertThrowsError(try ln.readCharacter(inputFile: dir))
        XCTAssertThrowsError(try ln.getLine(prompt: "> ")) { error in
            if case LinenoiseError.EOF = error {
                XCTFail("a read error must not look like end of input")
            }
        }
    }
}
