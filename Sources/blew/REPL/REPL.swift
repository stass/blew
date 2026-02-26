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

        ln.setCompletionCallback { [weak self] buffer in
            guard let self else { return [] }

            let parts = buffer.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)

            // Completing the command word itself
            if parts.count <= 1 {
                return commands
                    .filter { $0.hasPrefix(buffer) }
                    .map { $0 + " " }
            }

            let cmd = String(parts[0])
            let rest = parts.count > 1 ? String(parts[1]) : ""

            // --- connect: complete device IDs and names ---
            if cmd == "connect" {
                let partial = rest.lowercased()
                let strippedPartial = partial.replacingOccurrences(of: "-", with: "")
                var seen = Set<String>()
                var matches: [String] = []
                for device in self.router.lastScanResults {
                    let id = device.identifier
                    let nameMatch = device.name.map {
                        $0.lowercased().contains(partial)
                    } ?? false
                    // Match any contiguous portion of the UUID (hyphens stripped)
                    let strippedId = id.lowercased().replacingOccurrences(of: "-", with: "")
                    let idMatch = !strippedPartial.isEmpty && strippedId.contains(strippedPartial)
                    if nameMatch || idMatch {
                        if seen.insert(id).inserted {
                            matches.append("connect \(id) ")
                        }
                    }
                }
                return matches
            }

            // --- gatt subcommands ---
            if cmd == "gatt" {
                let gattParts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                let sub = gattParts.isEmpty ? "" : String(gattParts[0])

                // Still completing the subcommand itself
                if gattParts.count <= 1 && !rest.hasSuffix(" ") {
                    return gattSubs
                        .filter { $0.hasPrefix(sub) }
                        .map { "gatt \($0) " }
                }

                // gatt chars -S <service-uuid>
                if sub == "chars" {
                    if buffer.hasSuffix("-S ") || buffer.hasSuffix("--service ") {
                        return self.router.manager.knownServiceUUIDs()
                            .map { "\(buffer)\($0)" }
                    }
                    let flagPrefix = self.completionUUIDAfterFlag(
                        buffer: buffer,
                        flags: ["-S", "--service"],
                        candidates: self.router.manager.knownServiceUUIDs()
                    )
                    return flagPrefix
                }

                // gatt desc -c <char-uuid>
                if sub == "desc" {
                    if buffer.hasSuffix("-c ") || buffer.hasSuffix("--char ") {
                        return self.router.manager.knownCharacteristicUUIDs()
                            .map { "\(buffer)\($0)" }
                    }
                    return self.completionUUIDAfterFlag(
                        buffer: buffer,
                        flags: ["-c", "--char"],
                        candidates: self.router.manager.knownCharacteristicUUIDs()
                    )
                }

                return []
            }

            // --- format completion ---
            if ["-F", "--format"].contains(where: { buffer.hasSuffix($0 + " ") }) {
                return formats.map { "\(buffer)\($0)" }
            }

            // --- read / write / sub: complete -c <char-uuid> ---
            if ["read", "write", "sub"].contains(cmd) {
                if buffer.hasSuffix("-c ") || buffer.hasSuffix("--char ") {
                    return self.router.manager.knownCharacteristicUUIDs()
                        .map { "\(buffer)\($0)" }
                }
                return self.completionUUIDAfterFlag(
                    buffer: buffer,
                    flags: ["-c", "--char"],
                    candidates: self.router.manager.knownCharacteristicUUIDs()
                )
            }

            return []
        }
    }

    /// Given a buffer like `read -c 2A0` and a list of UUID candidates,
    /// returns completions where the last token (after one of the given flags) is
    /// extended to full matching UUIDs.
    private func completionUUIDAfterFlag(buffer: String, flags: [String], candidates: [String]) -> [String] {
        let tokens = buffer.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else { return [] }
        let lastFlag = tokens[tokens.count - 2]
        guard flags.contains(lastFlag) else { return [] }
        let partial = tokens.last!.lowercased()
        let prefix = buffer.hasSuffix(partial) ? String(buffer.dropLast(partial.count)) : buffer + " "
        return candidates
            .filter { $0.lowercased().hasPrefix(partial) }
            .map { "\(prefix)\($0)" }
    }
}
