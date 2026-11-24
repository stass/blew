import XCTest

/// No file of the output layer but `StandardStreams.swift` writes to stdout
/// or stderr, so every line the renderers print is a `TextLine`, a kv
/// record or a stderr message, each escaped on its way out. Swift's access
/// control cannot keep a file from calling the standard library's `print`
/// or `FileHandle.standardOutput`, so this reads the sources.
final class OutputSourceTests: XCTestCase {

    func testOnlyStandardStreamsWritesToStdoutOrStderr() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/blew/Output")
        let files = (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".swift") && $0 != "StandardStreams.swift" }
        XCTAssertTrue(files.contains("TextRenderer.swift"), "\(dir.path): \(files)")
        let forbidden = try NSRegularExpression(pattern: [
            #"\b(print|debugPrint|dump|NSLog|perror|puts|fputs|fputws|fputc|putchar|putc|fwrite|writev|printf|fprintf|vprintf|vfprintf)\s*\("#,
            #"\bfflush\s*\("#,
            #"\b(stdout|stderr|STDOUT_FILENO|STDERR_FILENO)\b"#,
            #"\.\s*standard(Output|Error)\b|FileHandle\s*\(\s*(fileDescriptor|forWriting)"#,
            #"/dev/(stdout|stderr|tty|fd/)"#,
            #"\bwrite\s*\(\s*[12]\s*,"#,
        ].joined(separator: "|"))
        for file in files {
            let source = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                // Whole-line comments only: a `//` inside a string literal
                // must not hide the code after it.
                let code = line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : line
                let range = NSRange(code.startIndex..., in: code)
                XCTAssertNil(forbidden.firstMatch(in: code, range: range),
                             "\(file):\(number + 1) writes to a standard stream: \(line)")
            }
        }
    }
}
