import XCTest

/// No file of `Sources/blew` but `Output/StandardStreams.swift` writes to
/// stdout or stderr, so every line blew prints is a `TextLine`, a kv
/// record, a stderr message or a redraw of a live display, each escaped on
/// its way out, and the bytes a user asks to stream raw go out through
/// `StandardOutput.writeRaw`. Swift's access control cannot keep a file from
/// calling the standard library's `print` or `FileHandle.standardOutput`,
/// so this reads the sources.
final class OutputSourceTests: XCTestCase {

    /// The one file allowed to match the patterns below.
    private static let writer = "Output/StandardStreams.swift"

    func testOnlyStandardStreamsWritesToStdoutOrStderr() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/blew")
        let files = (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(files.contains("CommandRouter.swift"), "\(dir.path): \(files)")
        XCTAssertTrue(files.contains("Output/TextRenderer.swift"), "\(dir.path): \(files)")
        let forbidden = try NSRegularExpression(pattern: [
            #"\b(print|debugPrint|dump|NSLog|perror|puts|fputs|fputws|fputc|putchar|putc|fwrite|writev|printf|fprintf|vprintf|vfprintf)\s*\("#,
            #"\bfflush\s*\("#,
            #"\b(stdout|stderr|STDOUT_FILENO|STDERR_FILENO)\b"#,
            #"\.\s*standard(Output|Error)\b|FileHandle\s*\(\s*(fileDescriptor|forWriting)"#,
            #"/dev/(stdout|stderr|tty|fd/)"#,
            #"\bwrite\s*\(\s*[12]\s*,"#,
        ].joined(separator: "|"))
        XCTAssertTrue(files.contains(Self.writer), "\(dir.path): \(files)")
        for file in files where file != Self.writer {
            let source = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                // Whole-line comments only: a `//` inside a string literal
                // must not hide the code after it.
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                XCTAssertNil(forbidden.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                             "\(file):\(number + 1) writes to a standard stream: \(line)")
            }
        }
    }
}
