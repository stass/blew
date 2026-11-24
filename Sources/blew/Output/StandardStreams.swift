import Foundation

// The only code in the output layer that writes to stdout and stderr.
// Each function takes text in a form that is escaped on the way out: a
// `TextLine` (escaped as it is built), kv pairs (values escaped by
// `KVText.value`) or a message (escaped by `TerminalText.escape`). Raw
// bytes go out only through `StandardOutput.writeRaw`, which takes a UART's
// received bytes (`NUSData`), the one stream the user asks to receive
// unchanged. `OutputSourceTests` checks that no
// other file under `Sources/blew/Output` writes to either stream.

enum StandardOutput {
    /// Whether stdout is a terminal, where text output carries ANSI styles.
    static var isTerminal: Bool { isatty(STDOUT_FILENO) != 0 }

    /// Writes `line` and a newline, with its styles as ANSI codes when
    /// `styled`.
    static func write(_ line: TextLine, styled: Bool) {
        Swift.print(line.rendered(styled: styled))
    }

    /// Writes one kv record (`KVText.record`) and a newline.
    static func write(record pairs: [(String, String)]) {
        Swift.print(KVText.record(pairs))
    }

    /// Writes a table as kv records (`KVText.records`), one line per row.
    static func write(recordsWithHeaders headers: [String], rows: [[String]]) {
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
    /// Writes one line to stderr: `prefix` (a literal of blew's own)
    /// followed by `message` escaped for the terminal. Every error, info,
    /// debug and `nus` status line goes out here.
    static func write(_ prefix: StaticString, _ message: String) {
        FileHandle.standardError.write(Data("\(prefix)\(TerminalText.escape(message))\n".utf8))
    }

    /// Writes `text`, escaped, as a line of its own while a prompt or a live
    /// display may hold the cursor: carriage return and erase-line first,
    /// CR LF after (the terminal may be in raw mode).
    static func writeLive(_ text: String) {
        FileHandle.standardError.write(Data("\r\u{1B}[K\(TerminalText.escape(text))\r\n".utf8))
    }
}
