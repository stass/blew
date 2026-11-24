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
        emit(frame(line, columns: terminalColumns, styled: styled))
    }

    /// Redraws a live display of several lines (`scan -w`): erases the
    /// `previous` lines it drew last and writes `lines`, each clipped to
    /// stderr's width and ending in a newline, in one write so the terminal
    /// never shows half a frame.
    static func redraw(_ lines: [TextLine], replacing previous: Int, styled: Bool) {
        emit(frame(lines, replacing: previous, columns: terminalColumns, styled: styled))
    }

    /// The bytes of a one-line redraw on a terminal `columns` wide (nil:
    /// not known, and not clipped).
    static func frame(_ line: TextLine, columns: Int?, styled: Bool) -> String {
        TerminalControl.eraseLine.sequence + clipped(line, to: columns).rendered(styled: styled)
    }

    /// The bytes of a redraw of several lines on a terminal `columns` wide
    /// (nil: not known, and not clipped). Clipped, each line takes one row,
    /// so the `lines.count` a display passes as `previous` next time is the
    /// number of rows to erase.
    static func frame(_ lines: [TextLine], replacing previous: Int, columns: Int?,
                      styled: Bool) -> String {
        TerminalControl.eraseLinesAbove(previous).sequence
            + lines.map { clipped($0, to: columns).rendered(styled: styled) + "\n" }.joined()
    }

    private static func clipped(_ line: TextLine, to columns: Int?) -> TextLine {
        columns.map { line.clipped(to: $0) } ?? line
    }

    /// The width of the terminal on stderr, asked at each redraw so a live
    /// display follows a resized window; nil when stderr is not a terminal
    /// or the terminal reports a width of 0 (a pty nobody sized), where the
    /// width is not known and lines are written whole.
    private static var terminalColumns: Int? {
        var size = winsize()
        guard ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return Int(size.ws_col)
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
