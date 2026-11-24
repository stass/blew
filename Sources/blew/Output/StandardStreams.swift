import Foundation

// The only code in blew that writes to stdout and stderr. Each function
// takes text in a form that is escaped on the way out: a `TextLine`
// (escaped as it is rendered), kv pairs (literal keys, values escaped by
// `KVText.value`) or a message (escaped by `TerminalText.escape`). The only
// other bytes written are the ANSI codes of `TextLine` styles and the
// `TerminalControl` sequences a live display redraws itself with. Raw bytes
// go out only through `StandardOutput.writeRaw`, which takes a UART's
// received bytes (`NUSData`), the one stream the user asks to receive
// unchanged. `OutputSourceTests` checks that no other file under
// `Sources/blew` writes to either stream.

enum StandardOutput {
    /// Whether stdout is a terminal, where text output carries ANSI styles.
    static var isTerminal: Bool { isatty(STDOUT_FILENO) != 0 }

    /// Makes stdout line-buffered when it is not a terminal, so a reader of
    /// a pipe or a file sees each record as it is printed
    /// (`blew -o kv sub ... >> log`). Called once, before any output.
    static func lineBufferUnlessTerminal() {
        if !isTerminal { setvbuf(stdout, nil, _IOLBF, 0) }
    }

    /// Writes out buffered text, before another writer (LineNoise's prompt)
    /// writes to the terminal.
    static func flush() {
        fflush(stdout)
    }

    /// Writes out buffered text unless another thread holds stdout (it may
    /// be blocked writing to a pipe nobody reads): the flush before a
    /// signalled exit, which must not wait.
    static func flushUnlessLocked() {
        if ftrylockfile(stdout) == 0 {
            fflush(stdout)
            funlockfile(stdout)
        }
    }

    /// Writes `line` and a newline, with its styles as ANSI codes when
    /// `styled`.
    static func write(_ line: TextLine, styled: Bool) {
        Swift.print(line.rendered(styled: styled))
    }

    /// Writes one kv record (`KVText.record`) and a newline.
    static func write(record pairs: [(KVKey, String)]) {
        Swift.print(KVText.record(pairs))
    }

    /// Writes a table as kv records (`KVText.records`), one line per row.
    static func write(recordsWithHeaders headers: [ColumnHeader], rows: [[String]]) {
        for line in KVText.records(headers: headers, rows: rows) {
            Swift.print(line)
        }
    }

    /// Writes the bytes a UART delivered unchanged, after any buffered
    /// text: `nus` in text mode is a byte stream.
    static func writeRaw(_ received: NUSData) {
        fflush(stdout)
        FileHandle.standardOutput.write(received.data)
    }
}

/// The size of a terminal in character cells, from one TIOCGWINSZ query; nil
/// for a dimension the terminal does not report.
struct TerminalSize {
    let columns: Int?
    let rows: Int?
}

enum StandardErrorLog {
    static var isTerminal: Bool { isatty(STDERR_FILENO) != 0 }

    /// Writes one line to stderr: `prefix` (a literal of blew's own)
    /// followed by `message` escaped for the terminal. Every error, info,
    /// debug and `nus` status line goes out here.
    static func write(_ prefix: StaticString, _ message: String) {
        emit("\(prefix)\(TerminalText.escape(message))\n")
    }

    /// Writes `text` a line at a time, each line escaped: a message of
    /// several lines, such as ArgumentParser's usage error.
    static func write(lines text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        emit(lines.map { TerminalText.escape(String($0)) + "\n" }.joined())
    }

    /// Writes `text`, escaped, as a line of its own while a prompt or a live
    /// display may hold the cursor: carriage return and erase-line first,
    /// CR LF after (the terminal may be in raw mode).
    static func writeLive(_ text: String) {
        emit("\(TerminalControl.eraseLine.sequence)\(TerminalText.escape(text))\r\n")
    }

    /// Redraws a one-line live display (the scan spinner): erases the
    /// cursor's line and writes `line`, clipped to stderr's width, leaving
    /// the cursor at its end.
    static func redraw(_ line: TextLine, styled: Bool) {
        emit(frame(line, columns: terminalSize.columns, styled: styled))
    }

    /// Redraws a live display of several lines (`scan -w`): erases the
    /// `previous` lines it drew last and writes `head` and `rows` as
    /// `frame(head:rows:overflow:replacing:terminal:styled:)` fits them to
    /// stderr's terminal, in one write so the terminal never shows half a
    /// frame. Returns the number of lines written: the `previous` of the
    /// next redraw and of the `erase` that ends the display.
    static func redraw(head: [TextLine], rows: [TextLine], overflow: (Int) -> TextLine,
                       replacing previous: Int, styled: Bool) -> Int {
        let frame = frame(head: head, rows: rows, overflow: overflow, replacing: previous,
                          terminal: terminalSize, styled: styled)
        emit(frame.text)
        return frame.lineCount
    }

    /// The bytes of a one-line redraw on a terminal `columns` wide (nil:
    /// not known, and not clipped).
    static func frame(_ line: TextLine, columns: Int?, styled: Bool) -> String {
        TerminalControl.eraseLine.sequence + clipped(line, to: columns).rendered(styled: styled)
    }

    /// One redraw of a live display of several lines: its bytes, and the
    /// number of lines they write, each ending in a newline.
    struct LiveFrame {
        let text: String
        let lineCount: Int
    }

    /// A redraw of `head` then `rows` on `terminal`. Every line is clipped
    /// to the terminal's width, so it takes one row. On a terminal `h`
    /// rows high the frame takes at most `h - 1` lines, so the newline
    /// after its last line does not scroll its first off the screen, where
    /// the next frame's cursor-up could not reach it. When `head` and
    /// `rows` do not fit, the lines are kept in order (the head first, then
    /// the rows from the top) and the last line is `overflow(n)`, `n` the
    /// rows not shown. A dimension the terminal does not report (nil)
    /// neither clips nor caps.
    static func frame(head: [TextLine], rows: [TextLine], overflow: (Int) -> TextLine,
                      replacing previous: Int, terminal: TerminalSize, styled: Bool) -> LiveFrame {
        var lines = head + rows
        if let height = terminal.rows, lines.count > height - 1 {
            let budget = max(height - 1, 0)
            if rows.isEmpty || budget == 0 {
                lines = Array(head.prefix(budget))
            } else {
                // One line of the budget is the overflow line; the head
                // takes what it can of the rest, the rows what remains.
                let shownRows = max(budget - 1 - head.count, 0)
                lines = Array(head.prefix(budget - 1)) + rows.prefix(shownRows)
                    + [overflow(rows.count - shownRows)]
            }
        }
        let text = TerminalControl.eraseLinesAbove(previous).sequence
            + lines.map { clipped($0, to: terminal.columns).rendered(styled: styled) + "\n" }.joined()
        return LiveFrame(text: text, lineCount: lines.count)
    }

    private static func clipped(_ line: TextLine, to columns: Int?) -> TextLine {
        columns.map { line.clipped(to: $0) } ?? line
    }

    /// The size of the terminal on stderr, asked at each redraw so a live
    /// display follows a resized window. A dimension is nil when stderr is
    /// not a terminal or the terminal reports it as 0 (a pty nobody sized):
    /// it is not known, and lines are neither clipped nor capped by it.
    private static var terminalSize: TerminalSize {
        var size = winsize()
        guard ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0 else { return TerminalSize(columns: nil, rows: nil) }
        return TerminalSize(columns: size.ws_col > 0 ? Int(size.ws_col) : nil,
                            rows: size.ws_row > 0 ? Int(size.ws_row) : nil)
    }

    /// Erases what a live display drew, when it stops.
    static func erase(_ control: TerminalControl) {
        emit(control.sequence)
    }

    private static func emit(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// The terminal control sequences a live display on stderr erases itself
/// with. They are blew's own; no case carries text.
enum TerminalControl {
    /// Carriage return and erase to end of line: the cursor's line is blank
    /// and the cursor at its start.
    case eraseLine
    /// Cursor up `count` lines and erase to end of screen: the last `count`
    /// lines written are gone. Nothing when `count` is not positive (a
    /// terminal reads a cursor-up of 0 as 1).
    case eraseLinesAbove(Int)

    fileprivate var sequence: String {
        switch self {
        case .eraseLine: return "\r\u{1B}[K"
        case .eraseLinesAbove(let count): return count > 0 ? "\u{1B}[\(count)A\u{1B}[J" : ""
        }
    }
}
