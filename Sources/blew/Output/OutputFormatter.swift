import Foundation

struct OutputFormatter {
    let format: OutputFormat
    let verbosity: Int
    let isTTY: Bool

    init(format: OutputFormat, verbosity: Int = 0) {
        self.format = format
        self.verbosity = verbosity
        self.isTTY = StandardOutput.isTerminal
    }

    // MARK: - Logging (stderr)

    func printError(_ message: String) {
        StandardErrorLog.write("Error: ", message)
    }

    func printInfo(_ message: String) {
        guard verbosity >= 1 else { return }
        StandardErrorLog.write("", message)
    }

    func printDebug(_ message: String) {
        guard verbosity >= 2 else { return }
        StandardErrorLog.write("[debug] ", message)
    }

    // MARK: - Output (stdout)

    /// Whether lines carry their ANSI styles: text output on a terminal.
    /// The `scan -w` display on stderr follows it too.
    var styled: Bool { isTTY && format == .text }

    /// Writes `line` to stdout, the one way the renderers print text.
    func write(_ line: TextLine) {
        StandardOutput.write(line, styled: styled)
    }

    func write(_ lines: [TextLine]) {
        for line in lines { write(line) }
    }

    func printRecord(_ pairs: (KVKey, String)...) {
        printRecord(pairs)
    }

    /// One record: in text mode a `key: value` line per pair, in kv mode one
    /// kv line. Values are untrusted and escaped for the format.
    func printRecord(_ pairs: [(KVKey, String)]) {
        switch format {
        case .text:
            for (key, value) in pairs {
                var line = TextLine(key.name, .bold)
                line.append(": ")
                line.append(value)
                write(line)
            }
        case .kv:
            StandardOutput.write(record: pairs)
        }
    }

    /// A table: in text mode laid out by `TextTable` (an empty table is one
    /// empty line), in kv mode one record per row.
    func printTable(headers: [ColumnHeader], rows: [[String]]) {
        switch format {
        case .text:
            let lines = TextTable.lines(headers: headers.map(\.title), rows: rows.map { TextTable.Row(cells: $0) })
            write(lines.isEmpty ? [TextLine()] : lines)
        case .kv:
            StandardOutput.write(recordsWithHeaders: headers, rows: rows)
        }
    }
}
