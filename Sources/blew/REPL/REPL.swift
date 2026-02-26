import Foundation
import LineNoise

final class REPL {
    private let globals: GlobalOptions
    private let router: CommandRouter
    private let ln: LineNoise
    private let historyPath: String

    init(globals: GlobalOptions) {
        self.globals = globals
        self.router = CommandRouter(globals: globals)
        self.ln = LineNoise()
        let configDir = NSHomeDirectory() + "/.config/blew"
        self.historyPath = configDir + "/history"

        setupHistoryDirectory(configDir)
        try? ln.loadHistory(fromFile: historyPath)
        setupCompletion()
    }

    func run() {
        print("blew v0.1.0 — type 'help' for commands, 'quit' to exit")

        while true {
            do {
                let line = try ln.getLine(prompt: "blew> ")
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

                // linenoise-swift doesn't write a newline when Enter is pressed (OPOST
                // is disabled in raw mode, so \n ≠ \r\n). Write one now while the
                // terminal is back in cooked mode so the cursor lands on a fresh line
                // before any command output (or the next prompt) is printed.
                FileHandle.standardOutput.write(Data("\n".utf8))

                ln.addHistory(trimmed)

                if trimmed == "quit" || trimmed == "exit" {
                    break
                }

                _ = router.dispatch(trimmed)

            } catch LinenoiseError.CTRL_C {
                print("^C")
                continue
            } catch LinenoiseError.EOF {
                break
            } catch {
                break
            }
        }

        try? ln.saveHistory(toFile: historyPath)
    }

    private func setupHistoryDirectory(_ dir: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    private func setupCompletion() {
        let commands = [
            "scan", "connect", "disconnect", "status",
            "gatt", "read", "write", "sub",
            "help", "quit", "exit",
        ]
        let gattSubs = ["svcs", "tree", "chars", "desc"]
        let formats = ["hex", "utf8", "base64", "uint8", "uint16le", "uint32le", "float32le", "raw"]

        ln.setCompletionCallback { buffer in
            let parts = buffer.split(separator: " ", maxSplits: 1)
            if parts.count <= 1 {
                return commands.filter { $0.hasPrefix(buffer) }
            }

            let cmd = String(parts[0])
            let rest = parts.count > 1 ? String(parts[1]) : ""

            if cmd == "gatt" {
                return gattSubs
                    .filter { $0.hasPrefix(rest) }
                    .map { "\(cmd) \($0)" }
            }

            if ["-F", "--format"].contains(where: { buffer.hasSuffix($0 + " ") }) {
                return formats.map { "\(buffer)\($0)" }
            }

            return []
        }
    }
}
