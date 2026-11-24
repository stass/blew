import Foundation

/// One line of text output: a sequence of runs, each with one style. The
/// runs hold text as it was added; every way out of a line escapes it with
/// `TerminalText.escape`, blew's own literals included (escaping them
/// changes nothing): `rendered` writes the escaped text, and `width` and
/// `clipped(to:)` measure it. The only bytes of a rendered line that are
/// not escaped text are the ANSI codes of its styles, so a line cannot
/// carry a device's control characters to the terminal.
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

    /// Text as added, one run per `append`; escaped on the way out.
    private var runs: [(style: Style, text: String)] = []

    init() {}

    init(_ text: String, _ style: Style = .plain) {
        append(text, style)
    }

    /// Adds `text` as a run in `style`.
    mutating func append(_ text: String, _ style: Style = .plain) {
        runs.append((style, text))
    }

    /// Adds the runs of `line`.
    mutating func append(_ line: TextLine) {
        runs += line.runs
    }

    /// The terminal columns the rendered line takes: the sum of
    /// `displayWidth(of:)` over its characters.
    var width: Int {
        var total = 0
        for run in runs {
            for character in run.text { total += Self.displayWidth(of: character) }
        }
        return total
    }

    /// The columns `character` takes once escaped: an escape sequence
    /// (`\x1b`) is as wide as its text. A line's width is defined as the
    /// sum over its characters, so `width` and `clipped(to:)` agree. Where
    /// an escaped control is followed by a mark, this counts one column
    /// more than the whole escaped text measures, never fewer.
    private static func displayWidth(of character: Character) -> Int {
        TerminalText.width(TerminalText.escape(String(character)))
    }

    /// The line cut to at most `columns` terminal columns, so a live display
    /// never wraps. A line that fits is returned whole. A longer one keeps
    /// the characters that fit in `columns - 1` and ends in `…` (one column)
    /// in the style of the run it was cut in. It is cut only between the
    /// characters that were added, never inside the escape sequence of one,
    /// a wide character or a style. Nothing fits in fewer than one column.
    func clipped(to columns: Int) -> TextLine {
        guard width > columns else { return self }
        guard columns > 0 else { return TextLine() }
        let budget = columns - 1
        var line = TextLine()
        var used = 0
        for run in runs {
            var kept = ""
            for character in run.text {
                let characterWidth = Self.displayWidth(of: character)
                if used + characterWidth > budget {
                    line.runs.append((run.style, kept + "…"))
                    return line
                }
                kept.append(character)
                used += characterWidth
            }
            line.runs.append((run.style, kept))
        }
        return line
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
            let text = TerminalText.escape(run.text)
            guard styled, let start = run.style.ansiStart else { return text }
            return "\(start)\(text)\u{1B}[0m"
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
