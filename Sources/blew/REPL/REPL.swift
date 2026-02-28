import Foundation
import LineNoise
import BLEManager

final class REPL {
    private let globals: GlobalOptions
    private let router: CommandRouter
    private let ln: LineNoise
    private let historyPath: String

    init(globals: GlobalOptions) {
        self.globals = globals
        self.router = CommandRouter(globals: globals, isInteractiveMode: true)
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

                // linenoise-swift doesn't write a newline when Enter is pressed (OPOST
                // is disabled in raw mode, so \n ≠ \r\n). Write one now while the
                // terminal is back in cooked mode so the cursor lands on a fresh line
                // before any command output (or the next prompt) is printed.
                FileHandle.standardOutput.write(Data("\n".utf8))

                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

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
            "gatt", "read", "write", "sub", "periph",
            "help", "quit", "exit",
        ]
        let gattSubs = ["svcs", "tree", "chars", "desc", "info"]
        let periphSubs = ["adv", "clone", "stop", "set", "notify", "status"]
        let subSubs = ["stop", "status"]
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

            // --- periph subcommands ---
            if cmd == "periph" {
                let periphParts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                let sub = periphParts.isEmpty ? "" : String(periphParts[0])

                if periphParts.count <= 1 && !rest.hasSuffix(" ") {
                    return periphSubs
                        .filter { $0.hasPrefix(sub) }
                        .map { "periph \($0) " }
                }

                // periph set / notify: complete characteristic UUID
                if sub == "set" || sub == "notify" {
                    let afterSub = periphParts.count > 1 ? String(periphParts[1]) : ""
                    let tokens = afterSub.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    let partial = tokens.last.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? ""
                    let candidates = BLEPeripheral.shared.knownCharacteristicUUIDs()
                    if partial.isEmpty && buffer.hasSuffix(" ") {
                        return candidates.map { "\(buffer)\($0)" }
                    }
                    if !partial.isEmpty && tokens.count == 1 {
                        let prefix = String(buffer.dropLast(partial.count))
                        return candidates
                            .filter { $0.lowercased().hasPrefix(partial.lowercased()) }
                            .map { "\(prefix)\($0)" }
                    }
                    return []
                }

                return []
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

                // gatt chars [-V] <service-uuid>: complete service UUID positionally
                if sub == "chars" {
                    let afterSub = gattParts.count > 1 ? String(gattParts[1]) : ""
                    // Find last non-flag token (the partial service UUID)
                    let tokens = afterSub.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    // Skip -V flag, look for first non-flag token
                    let partial = tokens.last.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? ""
                    if partial.isEmpty && buffer.hasSuffix(" ") {
                        return self.router.manager.knownServiceUUIDs()
                            .map { "\(buffer)\($0)" }
                    }
                    if !partial.isEmpty {
                        let prefix = String(buffer.dropLast(partial.count))
                        return self.router.manager.knownServiceUUIDs()
                            .filter { $0.lowercased().hasPrefix(partial.lowercased()) }
                            .map { "\(prefix)\($0)" }
                    }
                    return []
                }

                // gatt desc <char-uuid>: complete characteristic UUID positionally
                if sub == "desc" {
                    let afterSub = gattParts.count > 1 ? String(gattParts[1]) : ""
                    let tokens = afterSub.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    let partial = tokens.last.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? ""
                    if partial.isEmpty && buffer.hasSuffix(" ") {
                        return self.router.manager.knownCharacteristicUUIDs()
                            .map { "\(buffer)\($0)" }
                    }
                    if !partial.isEmpty {
                        let prefix = String(buffer.dropLast(partial.count))
                        return self.router.manager.knownCharacteristicUUIDs()
                            .filter { $0.lowercased().hasPrefix(partial.lowercased()) }
                            .map { "\(prefix)\($0)" }
                    }
                    return []
                }

                // gatt info <char-uuid>: no runtime UUIDs needed, return nothing
                return []
            }

            // --- format completion after -f ---
            if ["-f", "--format"].contains(where: { buffer.hasSuffix($0 + " ") }) {
                return formats.map { "\(buffer)\($0)" }
            }

            // --- sub: complete subcommands (stop/status) or positional char UUID ---
            if cmd == "sub" {
                let subParts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                let firstToken = subParts.isEmpty ? "" : String(subParts[0])

                // Offer subcommand completions when still typing the first token and it
                // matches "stop" or "status" (but not when it looks like a UUID/flag).
                if subParts.count <= 1 && !rest.hasSuffix(" ") {
                    let subMatches = subSubs.filter { $0.hasPrefix(firstToken) }
                    if !subMatches.isEmpty {
                        return subMatches.map { "sub \($0) " }
                    }
                }

                // sub stop <char-uuid>: complete characteristic UUID
                if firstToken == "stop" {
                    let afterSub = subParts.count > 1 ? String(subParts[1]) : ""
                    let partial = afterSub.trimmingCharacters(in: .whitespaces)
                    let candidates = self.router.manager.knownCharacteristicUUIDs()
                    if partial.isEmpty && buffer.hasSuffix(" ") {
                        return candidates.map { "\(buffer)\($0)" }
                    }
                    if !partial.isEmpty {
                        let prefix = String(buffer.dropLast(partial.count))
                        return candidates
                            .filter { $0.lowercased().hasPrefix(partial.lowercased()) }
                            .map { "\(prefix)\($0)" }
                    }
                    return []
                }

                // sub status: no further arguments
                if firstToken == "status" { return [] }

                // Default: complete positional char UUID
                return self.completionPositionalUUID(
                    buffer: buffer,
                    rest: rest,
                    optionsWithValue: ["-f", "--format", "-d", "--duration", "-c", "--count"],
                    candidates: self.router.manager.knownCharacteristicUUIDs()
                )
            }

            // --- read: complete positional char UUID ---
            if cmd == "read" {
                return self.completionPositionalUUID(
                    buffer: buffer,
                    rest: rest,
                    optionsWithValue: ["-f", "--format"],
                    candidates: self.router.manager.knownCharacteristicUUIDs()
                )
            }

            if cmd == "write" {
                // First positional is char, second is data — complete char UUID
                return self.completionPositionalUUID(
                    buffer: buffer,
                    rest: rest,
                    optionsWithValue: ["-f", "--format"],
                    candidates: self.router.manager.knownCharacteristicUUIDs()
                )
            }

            return []
        }
    }

    /// Complete the first positional (non-flag) argument in a command.
    /// Flags listed in `optionsWithValue` and their following token are skipped.
    private func completionPositionalUUID(
        buffer: String,
        rest: String,
        optionsWithValue: Set<String>,
        candidates: [String]
    ) -> [String] {
        let tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        // Collect positional tokens (skip flags and their values)
        var positionals: [String] = []
        var skipNext = false
        for token in tokens {
            if skipNext { skipNext = false; continue }
            if token.hasPrefix("-") {
                if optionsWithValue.contains(token) { skipNext = true }
            } else {
                positionals.append(token)
            }
        }

        // If buffer ends with a space we're starting a new token — offer candidates
        // only if no positional has been given yet
        if buffer.hasSuffix(" ") {
            if positionals.isEmpty {
                return candidates.map { "\(buffer)\($0)" }
            }
            return []
        }

        // Otherwise, the last positional is partial — complete it
        if positionals.count == 1 {
            let partial = positionals[0]
            let prefix = String(buffer.dropLast(partial.count))
            return candidates
                .filter { $0.lowercased().hasPrefix(partial.lowercased()) }
                .map { "\(prefix)\($0)" }
        }

        return []
    }
}
