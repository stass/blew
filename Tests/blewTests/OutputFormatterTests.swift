import XCTest
@testable import blew

final class OutputFormatterTests: XCTestCase {

    // MARK: - TextTable: text mode

    func testFormatTableEmptyRowsReturnsEmpty() {
        let result = textTable(headers: ["A", "B"], rows: [])
        XCTAssertEqual(result, "")
    }

    func testFormatTableSingleRow() {
        let result = textTable(headers: ["UUID", "Name"], rows: [["180F", "Battery Service"]])
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)  // header, separator, data row
        XCTAssertTrue(lines[0].contains("UUID"))
        XCTAssertTrue(lines[0].contains("Name"))
        XCTAssertTrue(lines[2].contains("180F"))
        XCTAssertTrue(lines[2].contains("Battery Service"))
    }

    func testFormatTableColumnsAligned() {
        let result = textTable(
            headers: ["ID", "Name"],
            rows: [
                ["short", "A Long Name"],
                ["much-longer-id", "B"],
            ]
        )
        let lines = result.components(separatedBy: "\n")
        // The header ID column should be as wide as "much-longer-id"
        XCTAssertTrue(lines[2].hasPrefix("short         "))
    }

    func testFormatTableMultipleRows() {
        let result = textTable(
            headers: ["A", "B"],
            rows: [["1", "x"], ["2", "y"], ["3", "z"]]
        )
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)  // header + sep + 3 rows
    }

    // MARK: - printRecord: KV mode

    func testKVRecordSimple() {
        let fmt = OutputFormatter(format: .kv, verbosity: 0)
        let output = captureStdout {
            fmt.printRecord(("key", "value"))
        }
        XCTAssertEqual(output.trimmingCharacters(in: .newlines), "key=value")
    }

    func testKVRecordMultiplePairs() {
        let fmt = OutputFormatter(format: .kv, verbosity: 0)
        let output = captureStdout {
            fmt.printRecord(("a", "1"), ("b", "2"), ("c", "3"))
        }
        XCTAssertEqual(output.trimmingCharacters(in: .newlines), "a=1 b=2 c=3")
    }

    func testKVRecordValueWithSpacesIsQuoted() {
        let fmt = OutputFormatter(format: .kv, verbosity: 0)
        let output = captureStdout {
            fmt.printRecord(("name", "Battery Service"))
        }
        XCTAssertEqual(output.trimmingCharacters(in: .newlines), "name=\"Battery Service\"")
    }

    func testKVRecordEmptyValueIsQuoted() {
        let fmt = OutputFormatter(format: .kv, verbosity: 0)
        let output = captureStdout {
            fmt.printRecord(("name", ""))
        }
        XCTAssertEqual(output.trimmingCharacters(in: .newlines), "name=\"\"")
    }

    func testKVRecordValueWithQuotesIsEscaped() {
        let fmt = OutputFormatter(format: .kv, verbosity: 0)
        let output = captureStdout {
            fmt.printRecord(("desc", "say \"hello\""))
        }
        XCTAssertEqual(output.trimmingCharacters(in: .newlines), "desc=\"say \\\"hello\\\"\"")
    }

    // MARK: - printRecord: text mode

    func testTextRecordSinglePair() {
        let fmt = OutputFormatter(format: .text, verbosity: 0)
        let output = captureStdout {
            fmt.printRecord(("connected", "yes"))
        }
        XCTAssertEqual(output.trimmingCharacters(in: .newlines), "connected: yes")
    }

    func testTextRecordMultiplePairs() {
        let fmt = OutputFormatter(format: .text, verbosity: 0)
        let output = captureStdout {
            fmt.printRecord(("a", "1"), ("b", "2"))
        }
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["a: 1", "b: 2"])
    }

    // MARK: - printTable: KV mode

    func testKVTable() {
        let fmt = OutputFormatter(format: .kv, verbosity: 0)
        let output = captureStdout {
            fmt.printTable(headers: ["UUID", "Name"], rows: [["180F", "Battery Service"]])
        }
        // Headers are lowercased; values with spaces quoted
        XCTAssertEqual(output.trimmingCharacters(in: .newlines), "uuid=180F name=\"Battery Service\"")
    }

    func testKVTableHeadersUnderscored() {
        let fmt = OutputFormatter(format: .kv, verbosity: 0)
        let output = captureStdout {
            fmt.printTable(headers: ["Device ID", "Signal Strength"], rows: [["ABC", "strong"]])
        }
        XCTAssertTrue(output.contains("device_id=ABC"))
        XCTAssertTrue(output.contains("signal_strength=strong"))
    }

    func testKVTableMultipleRows() {
        let fmt = OutputFormatter(format: .kv, verbosity: 0)
        let output = captureStdout {
            fmt.printTable(headers: ["ID", "Val"], rows: [["1", "a"], ["2", "b"]])
        }
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "id=1 val=a")
        XCTAssertEqual(lines[1], "id=2 val=b")
    }
}

// MARK: - Stdout capture helper

private func captureStdout(_ block: () -> Void) -> String {
    fflush(stdout)  // flush any buffered output from previous tests before redirecting
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

/// A text table as `TextTable` lays it out, unstyled, as one string of
/// newline-separated lines; empty when `rows` is.
func textTable(headers: [String], rows: [[String]]) -> String {
    TextTable.lines(headers: headers, rows: rows.map { TextTable.Row(cells: $0) })
        .map { $0.rendered(styled: false) }
        .joined(separator: "\n")
}
