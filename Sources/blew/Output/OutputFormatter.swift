import Foundation

struct OutputFormatter {
    let format: OutputFormat
    let verbosity: Int

    init(format: OutputFormat, verbosity: Int = 0) {
        self.format = format
        self.verbosity = verbosity
    }

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
                Swift.print("\(key): \(value)")
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
                h.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            Swift.print(header)
            Swift.print(String(repeating: "-", count: header.count))
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
}
