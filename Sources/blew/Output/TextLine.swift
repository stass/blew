import Foundation

/// One line of text output: a sequence of runs, each with one style. All
/// text is escaped with `TerminalText.escape` when it is added, blew's own
/// literals included (escaping them changes nothing), and no method adds a
/// `String` any other way. The only bytes of a rendered line that are not
/// escaped text are the ANSI codes of its styles, so a line cannot carry a
/// device's control characters to the terminal.
struct TextLine {
    enum Style {
        case plain, bold, dim

        /// The ANSI code that starts the style; nil for plain.
        fileprivate var ansiStart: String? {
            switch self {
            case .plain: return nil
            case .bold: return "\u{1B}[1m"
            case .dim: return "\u{1B}[2m"
            }
        }
    }

    /// Escaped text, one run per `append`.
    private var runs: [(style: Style, text: String)] = []

    init() {}

    init(_ text: String, _ style: Style = .plain) {
        append(text, style)
    }

    /// Adds `text`, escaped, as a run in `style`.
    mutating func append(_ text: String, _ style: Style = .plain) {
        runs.append((style, TerminalText.escape(text)))
    }

    /// Adds the runs of `line`.
    mutating func append(_ line: TextLine) {
        runs += line.runs
    }

    /// The terminal columns the line takes.
    var width: Int {
        runs.reduce(0) { $0 + TerminalText.width($1.text) }
    }

    /// Whether the line shows nothing: no text in any run.
    var isBlank: Bool {
        runs.allSatisfy { $0.text.isEmpty }
    }

    /// The line followed by spaces up to `columns` terminal columns, never
    /// truncated. The spaces join the last run, so a padded bold header
    /// stays one bold run.
    func padded(to columns: Int) -> TextLine {
        let spaces = String(repeating: " ", count: max(0, columns - width))
        var line = self
        if line.runs.isEmpty { line.runs.append((.plain, "")) }
        line.runs[line.runs.count - 1].text += spaces
        return line
    }

    /// The line after `columns` spaces. The spaces join the first run, so a
    /// dim line stays one dim run.
    func indented(by columns: Int) -> TextLine {
        let spaces = String(repeating: " ", count: max(0, columns))
        var line = self
        if line.runs.isEmpty { line.runs.append((.plain, "")) }
        line.runs[0].text = spaces + line.runs[0].text
        return line
    }

    /// The line's text, each styled run between its ANSI code and a reset
    /// when `styled`.
    func rendered(styled: Bool) -> String {
        runs.map { run in
            guard styled, let start = run.style.ansiStart else { return run.text }
            return "\(start)\(run.text)\u{1B}[0m"
        }.joined()
    }
}

/// Text tables: columns padded to their widest cell in terminal columns,
/// two spaces apart. This is the one layout for every table and aligned
/// field list in text output.
enum TextTable {
    struct Row {
        /// The padded cells, in column order; plain text, unlike
        /// `trailing` and `continuation`, which may carry styles.
        let cells: [String]
        /// Text after the padded cells, two spaces after them and not
        /// padded; left out with its two spaces when blank.
        var trailing = TextLine()
        /// Lines printed under the row, each indented to where `trailing`
        /// starts.
        var continuation: [TextLine] = []
    }

    /// The lines of a table, none when `rows` is empty. With `headers` (one
    /// per padded column, then `trailingHeader` over the trailing text), a
    /// bold header line and a dim rule as wide as it come first. Without,
    /// the column count is the longest row's and only the rows are printed.
    /// Every line starts with `indent` spaces. `trailingHeader` needs
    /// `headers`. Rows are expected to have one cell per column; a cell past
    /// the column count follows unpadded, and a short row ends early.
    static func lines(headers: [String]?, trailingHeader: String? = nil, indent: Int = 0,
                      rows: [Row]) -> [TextLine] {
        guard !rows.isEmpty else { return [] }
        let columnCount = headers?.count ?? rows.map(\.cells.count).max() ?? 0
        let cells = rows.map { $0.cells.map { TextLine($0) } }
        var widths = (0..<columnCount).map { TextLine(headers?[$0] ?? "").width }
        for row in cells {
            for (i, cell) in row.enumerated() where i < columnCount {
                widths[i] = max(widths[i], cell.width)
            }
        }

        var lines: [TextLine] = []
        if let headers {
            var header = joined(headers.enumerated().map { TextLine($1, .bold).padded(to: widths[$0]) })
            if let trailingHeader {
                header.append("  ")
                header.append(trailingHeader, .bold)
            }
            lines.append(header.indented(by: indent))
            lines.append(TextLine(String(repeating: "─", count: header.width), .dim).indented(by: indent))
        }
        let trailingColumn = indent + widths.reduce(0, +) + 2 * columnCount
        for (row, rowCells) in zip(rows, cells) {
            var line = joined(rowCells.enumerated().map { i, cell in
                i < columnCount ? cell.padded(to: widths[i]) : cell
            }).indented(by: indent)
            if !row.trailing.isBlank {
                line.append("  ")
                line.append(row.trailing)
            }
            lines.append(line)
            lines += row.continuation.map { $0.indented(by: trailingColumn) }
        }
        return lines
    }

    /// `parts` two spaces apart.
    private static func joined(_ parts: [TextLine]) -> TextLine {
        var line = TextLine()
        for (i, part) in parts.enumerated() {
            if i > 0 { line.append("  ") }
            line.append(part)
        }
        return line
    }
}
