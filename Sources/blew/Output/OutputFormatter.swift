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

    // MARK: - ANSI helpers

    /// `text`, escaped, in bold when styled: for text built outside the
    /// renderers, such as the help listing. Renderers build a `TextLine`.
    func bold(_ text: String) -> String {
        TextLine(text, .bold).rendered(styled: styled)
    }

    /// `text`, escaped, dimmed when styled; see `bold`.
    func dim(_ text: String) -> String {
        TextLine(text, .dim).rendered(styled: styled)
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
    private var styled: Bool { isTTY && format == .text }

    /// Writes `line` to stdout, the one way the renderers print text.
    func write(_ line: TextLine) {
        StandardOutput.write(line, styled: styled)
    }

    func write(_ lines: [TextLine]) {
        for line in lines { write(line) }
    }

    func printRecord(_ pairs: (String, String)...) {
        printRecord(pairs)
    }

    /// One record: in text mode a `key: value` line per pair, in kv mode one
    /// kv line. Values are untrusted and escaped for the format.
    func printRecord(_ pairs: [(String, String)]) {
        switch format {
        case .text:
            for (key, value) in pairs {
                var line = TextLine(key, .bold)
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
    func printTable(headers: [String], rows: [[String]]) {
        switch format {
        case .text:
            let lines = TextTable.lines(headers: headers, rows: rows.map { TextTable.Row(cells: $0) })
            write(lines.isEmpty ? [TextLine()] : lines)
        case .kv:
            StandardOutput.write(recordsWithHeaders: headers, rows: rows)
        }
    }

    /// A text table (`TextTable`) as one string of newline-separated lines,
    /// with ANSI bold and dim when styled; empty when `rows` is. Cells are
    /// untrusted and escaped.
    func formatTable(headers: [String], rows: [[String]]) -> String {
        TextTable.lines(headers: headers, rows: rows.map { TextTable.Row(cells: $0) })
            .map { $0.rendered(styled: styled) }
            .joined(separator: "\n")
    }
}
