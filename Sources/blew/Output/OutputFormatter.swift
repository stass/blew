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
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }

    func printInfo(_ message: String) {
        guard verbosity >= 1 else { return }
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    func printDebug(_ message: String) {
        guard verbosity >= 2 else { return }
        FileHandle.standardError.write(Data("[debug] \(message)\n".utf8))
    }

    // MARK: - Output (stdout)

    func print(_ text: String) {
        Swift.print(text)
    }

    func printRecord(_ pairs: (String, String)...) {
        printRecord(pairs)
    }

    func printRecord(_ pairs: [(String, String)]) {
        switch format {
        case .text:
            for (key, value) in pairs {
                Swift.print("\(bold(key)): \(value)")
            }
        case .kv:
            let line = pairs.map { key, value in
                if value.contains(" ") || value.contains("\"") || value.isEmpty {
                    return "\(key)=\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
                }
                return "\(key)=\(value)"
            }.joined(separator: " ")
            Swift.print(line)
        }
    }

    func printTable(headers: [String], rows: [[String]]) {
        switch format {
        case .text:
            guard !rows.isEmpty else { return }
            var widths = headers.map { $0.count }
            for row in rows {
                for (i, cell) in row.enumerated() where i < widths.count {
                    widths[i] = max(widths[i], cell.count)
                }
            }
            let header = headers.enumerated().map { i, h in
                bold(h).padding(toLength: widths[i] + boldPadding(h), withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            Swift.print(header)
            Swift.print(dim(String(repeating: "─", count: widths.reduce(0, +) + max(0, widths.count - 1) * 2)))
            for row in rows {
                let line = row.enumerated().map { i, cell in
                    cell.padding(toLength: i < widths.count ? widths[i] : cell.count, withPad: " ", startingAt: 0)
                }.joined(separator: "  ")
                Swift.print(line)
            }
        case .kv:
            let lowerHeaders = headers.map { $0.lowercased().replacingOccurrences(of: " ", with: "_") }
            for row in rows {
                let pairs = zip(lowerHeaders, row).map { key, value in
                    if value.contains(" ") || value.contains("\"") || value.isEmpty {
                        return "\(key)=\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
                    }
                    return "\(key)=\(value)"
                }.joined(separator: " ")
                Swift.print(pairs)
            }
        }
    }

    // MARK: - Private helpers

    // When we bold a header string, we add ANSI escape sequences that are invisible
    // but take up bytes. padding(toLength:) counts bytes, not visible characters,
    // so we need to widen the target length by the number of escape bytes added.
    private func boldPadding(_ text: String) -> Int {
        guard isTTY && format == .text else { return 0 }
        // bold() wraps with \e[1m (4 bytes) + \e[0m (4 bytes) = 8 extra bytes
        return 8
    }
}
