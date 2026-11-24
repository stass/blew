import Foundation

struct OutputFormatter {
    let format: OutputFormat
    let verbosity: Int
    let isTTY: Bool

    init(format: OutputFormat, verbosity: Int = 0) {
        self.format = format
        self.verbosity = verbosity
        self.isTTY = isatty(fileno(stdout)) != 0
    }

    // MARK: - ANSI helpers

    func bold(_ text: String) -> String {
        guard isTTY && format == .text else { return text }
        return "\u{1B}[1m\(text)\u{1B}[0m"
    }

    func dim(_ text: String) -> String {
        guard isTTY && format == .text else { return text }
        return "\u{1B}[2m\(text)\u{1B}[0m"
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

    func printRecord(_ pairs: (String, String)...) {
        printRecord(pairs)
    }

    /// One record: in text mode a `key: value` line per pair, in kv mode one
    /// kv line. Values are untrusted and escaped for the format.
    func printRecord(_ pairs: [(String, String)]) {
        switch format {
        case .text:
            for (key, value) in pairs {
                Swift.print("\(bold(key)): \(TerminalText.escape(value))")
            }
        case .kv:
            Swift.print(KVText.record(pairs))
        }
    }

    func printTable(headers: [String], rows: [[String]]) {
        switch format {
        case .text:
            Swift.print(formatTable(headers: headers, rows: rows))
        case .kv:
            for line in KVText.records(headers: headers, rows: rows) {
                Swift.print(line)
            }
        }
    }

    /// Build a formatted text table and return it as a string (without printing).
    /// Only meaningful in text mode; the string includes ANSI bold/dim escapes
    /// when isTTY is true. Returns an empty string when rows is empty.
    /// Cells are untrusted: each is escaped for the terminal, then measured
    /// and padded in terminal columns (`TerminalText.width`).
    func formatTable(headers: [String], rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        let cells = rows.map { $0.map(TerminalText.escape) }
        var widths = headers.map(TerminalText.width)
        for row in cells {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], TerminalText.width(cell))
            }
        }
        var lines: [String] = []
        let header = headers.enumerated().map { i, h in
            bold(TerminalText.pad(h, toWidth: widths[i]))
        }.joined(separator: "  ")
        lines.append(header)
        lines.append(dim(String(repeating: "─", count: widths.reduce(0, +) + max(0, widths.count - 1) * 2)))
        for row in cells {
            let line = row.enumerated().map { i, cell in
                i < widths.count ? TerminalText.pad(cell, toWidth: widths[i]) : cell
            }.joined(separator: "  ")
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
