import Foundation
import BLEManager

final class CommandRouter {
    let globals: GlobalOptions
    let manager: BLECentral
    let output: OutputFormatter
    private(set) var lastScanResults: [DiscoveredDevice] = []

    init(globals: GlobalOptions, manager: BLECentral? = nil) {
        self.globals = globals
        self.manager = manager ?? BLECentral.shared
        self.output = OutputFormatter(format: globals.out, verbosity: globals.verbose)
    }

    /// Execute a semicolon-separated script string. Returns exit code.
    func executeScript(_ script: String) -> Int32 {
        let segments = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let commands = segments.filter { !$0.isEmpty }

        if globals.dryRun {
            for (i, cmd) in commands.enumerated() {
                print("[\(i + 1)] \(cmd)")
            }
            return 0
        }

        var firstError: Int32 = 0
        for cmd in commands {
            let code = dispatch(cmd)
            if code != 0 {
                if firstError == 0 { firstError = code }
                if !globals.keepGoing {
                    return code
                }
            }
        }
        return firstError
    }

    /// Parse and dispatch a single command line. Returns exit code.
    func dispatch(_ line: String) -> Int32 {
        let tokens = tokenize(line)
        guard let first = tokens.first else { return 0 }

        switch first {
        case "scan":
            return runScan(Array(tokens.dropFirst()))
        case "connect":
            return runConnect(Array(tokens.dropFirst()))
        case "disconnect":
            return runDisconnect(Array(tokens.dropFirst()))
        case "status":
            return runStatus(Array(tokens.dropFirst()))
        case "gatt":
            return runGATT(Array(tokens.dropFirst()))
        case "read":
            return runRead(Array(tokens.dropFirst()))
        case "write":
            return runWrite(Array(tokens.dropFirst()))
        case "sub":
            return runSub(Array(tokens.dropFirst()))
        case "help":
            printHelp()
            return 0
        default:
            output.printError("unknown command '\(first)'")
            return BlewExitCode.invalidArguments.code
        }
    }

    func printHelp() {
        func cmd(_ name: String) -> String { output.bold(name) }
        let lines = [
            "Available commands:",
            "  \(cmd("scan")) [-w]",
            "  \(cmd("connect")) [<id>]",
            "  \(cmd("disconnect"))",
            "  \(cmd("status"))",
            "  \(cmd("gatt")) \(cmd("svcs"))",
            "  \(cmd("gatt")) \(cmd("tree")) [-d] [-r]",
            "  \(cmd("gatt")) \(cmd("chars")) [-r] <service>",
            "  \(cmd("gatt")) \(cmd("desc")) <char>",
            "  \(cmd("gatt")) \(cmd("info")) <char>",
            "  \(cmd("read")) [-f <fmt>] <char>",
            "  \(cmd("write")) [-f <fmt>] [-r|-w] <char> <data>",
            "  \(cmd("sub")) [-f <fmt>] [-d <sec>] [-c <n>] <char>",
            "  \(cmd("help"))",
            "  \(cmd("quit"))/\(cmd("exit"))",
        ]
        print(lines.joined(separator: "\n"))
    }

    private func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""

        for ch in line {
            if inQuote {
                if ch == quoteChar {
                    inQuote = false
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" || ch == "'" {
                inQuote = true
                quoteChar = ch
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    // MARK: - Command runners (called from REPL/exec)

    func runScan(_ args: [String]) -> Int32 {
        let watchMode = args.contains("--watch") || args.contains("-w")
        let nameFilter = parseStringOption(args, short: "-n", long: "--name") ?? globals.name
        let rssiMin = parseIntOption(args, short: "-r", long: "--rssi-min") ?? globals.rssiMin

        if watchMode {
            return runScanWatch(nameFilter: nameFilter, rssiMin: rssiMin)
        }

        let scanTimeout = parseDoubleOption(args, short: "-t", long: "--timeout") ?? globals.timeout ?? 5.0

        let interactive = isatty(fileno(stderr)) != 0
        let spinner: ScanSpinner? = interactive ? ScanSpinner(timeout: scanTimeout) : nil
        if !interactive {
            output.printInfo("scanning for \(scanTimeout)s...")
        }
        spinner?.start()

        let semaphore = DispatchSemaphore(value: 0)
        var deviceMap: [String: DiscoveredDevice] = [:]
        var scanError: Int32 = 0

        let task = Task {
            defer { semaphore.signal() }
            do {
                let stream = try await manager.scan(timeout: scanTimeout)
                for await device in stream {
                    if let nameFilter = nameFilter {
                        guard let dName = device.name, dName.localizedCaseInsensitiveContains(nameFilter) else { continue }
                    }
                    if let rssiMin = rssiMin {
                        guard device.rssi >= rssiMin else { continue }
                    }
                    if let existing = deviceMap[device.identifier] {
                        var updated = device
                        if updated.name == nil && existing.name != nil {
                            updated = DiscoveredDevice(
                                identifier: updated.identifier,
                                name: existing.name,
                                rssi: updated.rssi,
                                serviceUUIDs: updated.serviceUUIDs.isEmpty ? existing.serviceUUIDs : updated.serviceUUIDs,
                                manufacturerData: updated.manufacturerData ?? existing.manufacturerData
                            )
                        }
                        deviceMap[device.identifier] = updated
                    } else {
                        deviceMap[device.identifier] = device
                    }
                    spinner?.deviceCount = deviceMap.count
                }
            } catch is CancellationError {
                // scan interrupted; partial results will still be printed below
            } catch {
                output.printError("\(error)")
                scanError = BlewExitCode.operationFailed.code
            }
        }

        // Scan manages its own duration; no external timeout needed.
        let outcome = waitInterruptible(task, semaphore: semaphore)
        spinner?.stop()

        if case .interrupted = outcome { return 130 }

        if scanError != 0 { return scanError }

        let devices = Array(deviceMap.values)
        if devices.isEmpty {
            output.printError("no devices found")
            return BlewExitCode.notFound.code
        }

        let sorted = devices.sorted { $0.rssi > $1.rssi }
        lastScanResults = sorted

        if output.format == .text {
            let headers = ["ID", "Name", "RSSI", "Signal", "Services"]
            let rows: [[String]] = sorted.map { d in
                [
                    d.identifier,
                    d.name ?? "(unknown)",
                    "\(d.rssi)",
                    Self.rssiBar(d.rssi),
                    d.serviceUUIDs.map { BLENames.displayUUID($0, category: .service) }.joined(separator: ", "),
                ]
            }
            output.printTable(headers: headers, rows: rows)
        } else {
            let headers = ["ID", "Name", "RSSI", "Services"]
            let rows: [[String]] = sorted.map { d in
                [
                    d.identifier,
                    d.name ?? "(unknown)",
                    "\(d.rssi)",
                    d.serviceUUIDs.joined(separator: ","),
                ]
            }
            output.printTable(headers: headers, rows: rows)
        }
        return 0
    }

    private func runScanWatch(nameFilter: String?, rssiMin: Int?) -> Int32 {
        // KV mode: stream a line per update to stdout without any terminal control.
        if output.format == .kv {
            return runScanWatchKV(nameFilter: nameFilter, rssiMin: rssiMin)
        }

        // Text mode requires a TTY for in-place redraw.
        guard isatty(fileno(stdout)) != 0 else {
            output.printError("scan --watch in text mode requires an interactive terminal; use -o kv for piped output")
            return BlewExitCode.invalidArguments.code
        }

        let watchTimeout: TimeInterval? = globals.timeout

        let display = ScanWatchDisplay(formatter: output)
        display.start()

        let semaphore = DispatchSemaphore(value: 0)
        var scanError: Int32 = 0
        var deviceMap: [String: DiscoveredDevice] = [:]

        let task = Task {
            defer { semaphore.signal() }
            do {
                let stream = try await manager.scan(timeout: watchTimeout, allowDuplicates: true)
                for await device in stream {
                    if let nameFilter = nameFilter {
                        guard let dName = device.name, dName.localizedCaseInsensitiveContains(nameFilter) else { continue }
                    }
                    if let rssiMin = rssiMin {
                        guard device.rssi >= rssiMin else { continue }
                    }
                    // Merge: preserve name/services/manufacturer seen in earlier advertisements.
                    if let existing = deviceMap[device.identifier] {
                        var updated = device
                        if updated.name == nil && existing.name != nil {
                            updated = DiscoveredDevice(
                                identifier: updated.identifier,
                                name: existing.name,
                                rssi: updated.rssi,
                                serviceUUIDs: updated.serviceUUIDs.isEmpty ? existing.serviceUUIDs : updated.serviceUUIDs,
                                manufacturerData: updated.manufacturerData ?? existing.manufacturerData
                            )
                        }
                        deviceMap[device.identifier] = updated
                    } else {
                        deviceMap[device.identifier] = device
                    }
                    let sorted = deviceMap.values.sorted { $0.rssi > $1.rssi }
                    display.update(devices: sorted)
                }
            } catch is CancellationError {
                // normal exit path
            } catch {
                output.printError("\(error)")
                scanError = BlewExitCode.operationFailed.code
            }
        }

        let outcome = waitInterruptible(task, semaphore: semaphore)
        display.stop()

        if case .interrupted = outcome {
            // Print final table to stdout so it persists in scroll history.
            let sorted = deviceMap.values.sorted { $0.rssi > $1.rssi }
            lastScanResults = sorted
            printScanTable(sorted)
            return 130
        }

        if scanError != 0 { return scanError }

        let sorted = deviceMap.values.sorted { $0.rssi > $1.rssi }
        lastScanResults = sorted
        if sorted.isEmpty {
            output.printError("no devices found")
            return BlewExitCode.notFound.code
        }
        printScanTable(sorted)
        return 0
    }

    private func runScanWatchKV(nameFilter: String?, rssiMin: Int?) -> Int32 {
        let watchTimeout: TimeInterval? = globals.timeout

        let semaphore = DispatchSemaphore(value: 0)
        var scanError: Int32 = 0
        var deviceMap: [String: DiscoveredDevice] = [:]

        let task = Task {
            defer { semaphore.signal() }
            do {
                let stream = try await manager.scan(timeout: watchTimeout, allowDuplicates: true)
                for await device in stream {
                    if let nameFilter = nameFilter {
                        guard let dName = device.name, dName.localizedCaseInsensitiveContains(nameFilter) else { continue }
                    }
                    if let rssiMin = rssiMin {
                        guard device.rssi >= rssiMin else { continue }
                    }
                    if let existing = deviceMap[device.identifier] {
                        var updated = device
                        if updated.name == nil && existing.name != nil {
                            updated = DiscoveredDevice(
                                identifier: updated.identifier,
                                name: existing.name,
                                rssi: updated.rssi,
                                serviceUUIDs: updated.serviceUUIDs.isEmpty ? existing.serviceUUIDs : updated.serviceUUIDs,
                                manufacturerData: updated.manufacturerData ?? existing.manufacturerData
                            )
                        }
                        deviceMap[device.identifier] = updated
                    } else {
                        deviceMap[device.identifier] = device
                    }
                    let d = deviceMap[device.identifier]!
                    output.printRecord(
                        ("id", d.identifier),
                        ("name", d.name ?? ""),
                        ("rssi", "\(d.rssi)"),
                        ("services", d.serviceUUIDs.joined(separator: ","))
                    )
                }
            } catch is CancellationError {
                // normal exit
            } catch {
                output.printError("\(error)")
                scanError = BlewExitCode.operationFailed.code
            }
        }

        let outcome = waitInterruptible(task, semaphore: semaphore)
        if case .interrupted = outcome {
            lastScanResults = deviceMap.values.sorted { $0.rssi > $1.rssi }
            return 130
        }
        if scanError != 0 { return scanError }
        lastScanResults = deviceMap.values.sorted { $0.rssi > $1.rssi }
        return 0
    }

    private func printScanTable(_ sorted: [DiscoveredDevice]) {
        guard !sorted.isEmpty else { return }
        let headers = ["ID", "Name", "RSSI", "Signal", "Services"]
        let rows: [[String]] = sorted.map { d in
            [
                d.identifier,
                d.name ?? "(unknown)",
                "\(d.rssi)",
                Self.rssiBar(d.rssi),
                d.serviceUUIDs.map { BLENames.displayUUID($0, category: .service) }.joined(separator: ", "),
            ]
        }
        output.printTable(headers: headers, rows: rows)
    }

    func runConnect(_ args: [String]) -> Int32 {
        let deviceId = args.first ?? globals.id
        let connectTimeout = globals.timeout ?? 10.0

        guard let rawInput = deviceId else {
            output.printError("missing device identifier")
            return BlewExitCode.invalidArguments.code
        }

        let resolved = resolveDevice(rawInput)
        if case .ambiguous(let matches) = resolved {
            output.printError("ambiguous device '\(rawInput)' — matches:")
            for d in matches {
                let label = d.name.map { "\($0) (\(d.identifier))" } ?? d.identifier
                output.printError("  \(label)")
            }
            return BlewExitCode.invalidArguments.code
        }

        let targetId: String
        if case .resolved(let device) = resolved {
            let label = device.name.map { "\($0) (\(device.identifier))" } ?? device.identifier
            output.printInfo("resolved '\(rawInput)' → \(label)")
            targetId = device.identifier
        } else {
            targetId = rawInput
        }

        output.printInfo("connecting to \(targetId)...")

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        let task = Task {
            defer { semaphore.signal() }
            do {
                try await manager.connect(deviceId: targetId, timeout: connectTimeout)
                output.printInfo("connected to \(targetId)")
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch let error as BLEError {
                output.printError(error.localizedDescription)
                exitCode = error.exitCode
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(task, semaphore: semaphore, timeout: connectTimeout) {
        case .completed: break
        case .interrupted: exitCode = 130
        case .timedOut:
            output.printError("connection timed out")
            exitCode = BlewExitCode.timeout.code
        }
        return exitCode
    }

    func runDisconnect(_ args: [String]) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        let task = Task {
            defer { semaphore.signal() }
            do {
                try await manager.disconnect()
                output.printInfo("disconnected")
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch let error as BLEError {
                output.printError(error.localizedDescription)
                exitCode = error.exitCode
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(task, semaphore: semaphore, timeout: globals.timeout ?? 5.0) {
        case .completed: break
        case .interrupted: exitCode = 130
        case .timedOut:
            output.printError("disconnect timed out")
            exitCode = BlewExitCode.timeout.code
        }
        return exitCode
    }

    func runStatus(_ args: [String]) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)

        let task = Task {
            defer { semaphore.signal() }
            let status = await manager.status()
            output.printRecord(
                ("connected", status.isConnected ? "yes" : "no"),
                ("device", status.deviceId ?? "(none)"),
                ("name", status.deviceName ?? "(none)"),
                ("services", "\(status.servicesCount)"),
                ("characteristics", "\(status.characteristicsCount)"),
                ("subscriptions", "\(status.subscriptionsCount)")
            )
            if let lastError = status.lastError {
                output.printRecord(("last_error", lastError))
            }
        }

        waitInterruptible(task, semaphore: semaphore)
        return 0
    }

    func runGATT(_ args: [String]) -> Int32 {
        guard let sub = args.first else {
            output.printError("missing subcommand")
            print("Usage: gatt <svcs|tree|chars|desc|info>")
            return BlewExitCode.invalidArguments.code
        }

        // info does not require a connected device
        if sub == "info" {
            return runGATTInfo(Array(args.dropFirst()))
        }


        let connectCode = ensureConnected()
        guard connectCode == 0 else { return connectCode }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        let task = Task {
            defer { semaphore.signal() }
            do {
                switch sub {
                case "svcs":
                    let services = try await manager.discoverServices()
                    let headers = ["UUID", "Name", "Primary"]
                    let rows = services.map { svc -> [String] in
                        let name = BLENames.name(for: svc.uuid, category: .service) ?? ""
                        return [svc.uuid, name, svc.isPrimary ? "yes" : "no"]
                    }
                    output.printTable(headers: headers, rows: rows)

                case "tree":
                    let includeDescriptors = args.contains("-d") || args.contains("--descriptors")
                    let includeValues = args.contains("-r") || args.contains("--read")
                    let tree = try await manager.discoverTree(includeDescriptors: includeDescriptors)
                    for (svcIdx, service) in tree.enumerated() {
                        let svcName = BLENames.name(for: service.uuid, category: .service)
                        var svcLine = "Service \(output.bold(service.uuid))"
                        if let name = svcName { svcLine += "  \(name)" }
                        output.print(svcLine)

                        for (charIdx, char) in service.characteristics.enumerated() {
                            let isLastChar = charIdx == service.characteristics.count - 1
                            let charBranch = isLastChar ? "└── " : "├── "
                            let descIndent = isLastChar ? "    " : "│   "
                            // Value lines are indented under the char, at the same depth as descriptors
                            let valueIndent = descIndent + "  "

                            let charName = BLENames.name(for: char.uuid, category: .characteristic)
                            let props = char.properties.joined(separator: ", ")
                            var charLine = charBranch + output.bold(char.uuid)
                            if let name = charName { charLine += "  \(name)" }
                            charLine += "  \(output.dim("[\(props)]"))"

                            if includeValues && char.properties.contains("read") {
                                do {
                                    let data = try await manager.readCharacteristic(char.uuid)
                                    let decoded = GATTDecoder.decode(data, uuid: char.uuid)
                                        ?? DataFormatter.format(data, as: "hex")
                                    let parts = decoded.components(separatedBy: " | ")
                                    if parts.count > 1 {
                                        // Multi-field: print char header first, then each field on its own line
                                        output.print(charLine)
                                        for part in parts {
                                            let (label, value) = Self.splitFieldPart(part)
                                            output.print(output.dim(valueIndent + label + ": ") + value)
                                        }
                                    } else {
                                        // Single-field: dim the "= " separator, normal weight for the value
                                        output.print(charLine + output.dim("  = ") + decoded)
                                    }
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    output.print(charLine + output.dim("  = (read error)"))
                                }
                            } else {
                                output.print(charLine)
                            }

                            for (descIdx, desc) in char.descriptors.enumerated() {
                                let isLastDesc = descIdx == char.descriptors.count - 1
                                let descBranch = isLastDesc ? "└── " : "├── "
                                let descName = BLENames.name(for: desc.uuid, category: .descriptor)
                                var descLine = descIndent + descBranch + output.dim(desc.uuid)
                                if let name = descName { descLine += output.dim("  \(name)") }
                                output.print(descLine)
                            }
                        }

                        if svcIdx < tree.count - 1 { output.print("") }
                    }

                case "chars":
                    let charsPositional = positionalArgs(Array(args.dropFirst()), optionsWithValue: [])
                    guard let svcInput = charsPositional.first else {
                        output.printError("missing service UUID")
                        exitCode = BlewExitCode.invalidArguments.code
                        return
                    }
                    let svcUUID: String
                    switch resolveService(svcInput) {
                    case .resolved(let uuid): svcUUID = uuid
                    case .ambiguous(let uuids):
                        output.printError("ambiguous service '\(svcInput)' — matches: \(uuids.joined(separator: ", "))")
                        exitCode = BlewExitCode.invalidArguments.code
                        return
                    case .notFound: svcUUID = svcInput
                    }
                    let includeValues = args.contains("-r") || args.contains("--read")
                    let chars = try await manager.discoverCharacteristics(forService: svcUUID)
                    if includeValues {
                        var rows: [[String]] = []
                        for char in chars {
                            let name = BLENames.name(for: char.uuid, category: .characteristic) ?? ""
                            var value = ""
                            if char.properties.contains("read") {
                                do {
                                    let data = try await manager.readCharacteristic(char.uuid)
                                    value = GATTDecoder.decode(data, uuid: char.uuid)
                                        ?? DataFormatter.format(data, as: "hex")
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    value = "(read error)"
                                }
                            }
                            rows.append([char.uuid, name, char.properties.joined(separator: ","), value])
                        }
                        output.printTable(headers: ["UUID", "Name", "Properties", "Value"], rows: rows)
                    } else {
                        let rows = chars.map { char -> [String] in
                            let name = BLENames.name(for: char.uuid, category: .characteristic) ?? ""
                            return [char.uuid, name, char.properties.joined(separator: ",")]
                        }
                        output.printTable(headers: ["UUID", "Name", "Properties"], rows: rows)
                    }

                case "desc":
                    let descPositional = positionalArgs(Array(args.dropFirst()), optionsWithValue: [])
                    guard let charInput = descPositional.first else {
                        output.printError("missing characteristic UUID")
                        exitCode = BlewExitCode.invalidArguments.code
                        return
                    }
                    let charUUID: String
                    switch resolveCharacteristic(charInput) {
                    case .resolved(let uuid): charUUID = uuid
                    case .ambiguous(let uuids):
                        output.printError("ambiguous characteristic '\(charInput)' — matches: \(uuids.joined(separator: ", "))")
                        exitCode = BlewExitCode.invalidArguments.code
                        return
                    case .notFound: charUUID = charInput
                    }
                    let descs = try await manager.discoverDescriptors(forCharacteristic: charUUID)
                    let headers = ["UUID", "Name"]
                    let rows = descs.map { desc -> [String] in
                        let name = BLENames.name(for: desc.uuid, category: .descriptor) ?? ""
                        return [desc.uuid, name]
                    }
                    output.printTable(headers: headers, rows: rows)

                default:
                    output.printError("unknown gatt subcommand '\(sub)'")
                    print("Usage: gatt <svcs|tree|chars|desc|info>")
                    exitCode = BlewExitCode.invalidArguments.code
                }
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch let error as BLEError {
                output.printError(error.localizedDescription)
                exitCode = error.exitCode
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(task, semaphore: semaphore, timeout: globals.timeout ?? 10.0) {
        case .completed: break
        case .interrupted: exitCode = 130
        case .timedOut:
            output.printError("operation timed out")
            exitCode = BlewExitCode.timeout.code
        }
        return exitCode
    }

    private func runGATTInfo(_ args: [String]) -> Int32 {
        guard let charInput = positionalArgs(args, optionsWithValue: []).first else {
            output.printError("missing characteristic UUID")
            return BlewExitCode.invalidArguments.code
        }

        guard let info = GATTDecoder.info(for: charInput) else {
            output.printError("no Bluetooth SIG definition found for '\(charInput)'")
            return BlewExitCode.notFound.code
        }

        switch output.format {
        case .text:
            output.print("\(output.bold("\(info.name) (\(info.uuid))"))")
            output.print("")
            output.print(info.description)
            if !info.fields.isEmpty {
                output.print("")
                output.print(output.bold("Structure:"))
                let nameWidth = info.fields.map { $0.name.count }.max() ?? 0
                let typeWidth = info.fields.map { $0.typeName.count }.max() ?? 0
                for f in info.fields {
                    var line = "  \(f.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))"
                    line += "  \(f.typeName.padding(toLength: typeWidth, withPad: " ", startingAt: 0))"
                    line += "  \(f.sizeDescription)"
                    if let cond = f.conditionDescription {
                        line += "  \(output.dim("[\(cond)]"))"
                    }
                    output.print(line)
                }
            }
        case .kv:
            output.printRecord(("uuid", info.uuid), ("name", info.name), ("description", info.description))
            for f in info.fields {
                var pairs: [(String, String)] = [
                    ("field", f.name),
                    ("type", f.typeName),
                    ("size", f.sizeDescription),
                ]
                if let cond = f.conditionDescription {
                    pairs.append(("condition", cond))
                }
                output.printRecord(pairs)
            }
        }
        return 0
    }

    func runRead(_ args: [String]) -> Int32 {
        let connectCode = ensureConnected()
        guard connectCode == 0 else { return connectCode }

        guard let charInput = positionalArgs(args, optionsWithValue: ["-f", "--format"]).first else {
            output.printError("missing characteristic UUID")
            return BlewExitCode.invalidArguments.code
        }
        let charUUID: String
        switch resolveCharacteristic(charInput) {
        case .resolved(let uuid): charUUID = uuid
        case .ambiguous(let uuids):
            output.printError("ambiguous characteristic '\(charInput)' — matches: \(uuids.joined(separator: ", "))")
            return BlewExitCode.invalidArguments.code
        case .notFound: charUUID = charInput
        }
        let fmt = parseStringOption(args, short: "-f", long: "--format") ?? "hex"

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        let task = Task {
            defer { semaphore.signal() }
            do {
                let data = try await manager.readCharacteristic(charUUID)
                let formatted = DataFormatter.format(data, as: fmt)
                switch output.format {
                case .text:
                    output.print(formatted)
                case .kv:
                    if let name = BLENames.name(for: charUUID, category: .characteristic) {
                        output.printRecord(("char", charUUID), ("name", name), ("value", formatted), ("fmt", fmt))
                    } else {
                        output.printRecord(("char", charUUID), ("value", formatted), ("fmt", fmt))
                    }
                }
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch let error as BLEError {
                output.printError(error.localizedDescription)
                exitCode = error.exitCode
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(task, semaphore: semaphore, timeout: globals.timeout ?? 5.0) {
        case .completed: break
        case .interrupted: exitCode = 130
        case .timedOut:
            output.printError("read timed out")
            exitCode = BlewExitCode.timeout.code
        }
        return exitCode
    }

    func runWrite(_ args: [String]) -> Int32 {
        let connectCode = ensureConnected()
        guard connectCode == 0 else { return connectCode }

        let positional = positionalArgs(args, optionsWithValue: ["-f", "--format"])
        guard positional.count >= 2 else {
            if positional.isEmpty {
                output.printError("missing characteristic UUID and data")
            } else {
                output.printError("missing data to write")
            }
            return BlewExitCode.invalidArguments.code
        }
        let charInput = positional[0]
        let dataStr = positional[1]
        let charUUID: String
        switch resolveCharacteristic(charInput) {
        case .resolved(let uuid): charUUID = uuid
        case .ambiguous(let uuids):
            output.printError("ambiguous characteristic '\(charInput)' — matches: \(uuids.joined(separator: ", "))")
            return BlewExitCode.invalidArguments.code
        case .notFound: charUUID = charInput
        }
        let fmt = parseStringOption(args, short: "-f", long: "--format") ?? "hex"
        let withResponse = args.contains("-r") || args.contains("--with-response")
        let withoutResponse = args.contains("-w") || args.contains("--without-response")

        guard let data = DataFormatter.parse(dataStr, as: fmt) else {
            output.printError("invalid data '\(dataStr)' for format '\(fmt)'")
            return BlewExitCode.invalidArguments.code
        }

        let writeType: WriteType
        if withResponse {
            writeType = .withResponse
        } else if withoutResponse {
            writeType = .withoutResponse
        } else {
            writeType = .auto
        }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        let task = Task {
            defer { semaphore.signal() }
            do {
                try await manager.writeCharacteristic(charUUID, data: data, type: writeType)
                output.printInfo("written to \(BLENames.displayUUID(charUUID, category: .characteristic))")
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch let error as BLEError {
                output.printError(error.localizedDescription)
                exitCode = error.exitCode
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(task, semaphore: semaphore, timeout: globals.timeout ?? 5.0) {
        case .completed: break
        case .interrupted: exitCode = 130
        case .timedOut:
            output.printError("write timed out")
            exitCode = BlewExitCode.timeout.code
        }
        return exitCode
    }

    func runSub(_ args: [String]) -> Int32 {
        let connectCode = ensureConnected()
        guard connectCode == 0 else { return connectCode }

        guard let charInput = positionalArgs(args, optionsWithValue: ["-f", "--format", "-d", "--duration", "-c", "--count"]).first else {
            output.printError("missing characteristic UUID")
            return BlewExitCode.invalidArguments.code
        }
        let charUUID: String
        switch resolveCharacteristic(charInput) {
        case .resolved(let uuid): charUUID = uuid
        case .ambiguous(let uuids):
            output.printError("ambiguous characteristic '\(charInput)' — matches: \(uuids.joined(separator: ", "))")
            return BlewExitCode.invalidArguments.code
        case .notFound: charUUID = charInput
        }
        let fmt = parseStringOption(args, short: "-f", long: "--format") ?? "hex"
        let duration = parseDoubleOption(args, short: "-d", long: "--duration")
        let maxCount = parseIntOption(args, short: "-c", long: "--count")

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        let task = Task {
            defer { semaphore.signal() }
            do {
                let stream = try await manager.subscribe(characteristicUUID: charUUID)
                var count = 0
                let startTime = Date()

                let charName = BLENames.name(for: charUUID, category: .characteristic)
                for await data in stream {
                    let formatted = DataFormatter.format(data, as: fmt)
                    switch output.format {
                    case .text:
                        output.print(formatted)
                    case .kv:
                        let ts = ISO8601DateFormatter.shared.string(from: Date())
                        if let name = charName {
                            output.printRecord(("ts", ts), ("char", charUUID), ("name", name), ("value", formatted))
                        } else {
                            output.printRecord(("ts", ts), ("char", charUUID), ("value", formatted))
                        }
                    }

                    count += 1
                    if let maxCount = maxCount, count >= maxCount { break }
                    if let duration = duration, Date().timeIntervalSince(startTime) >= duration { break }
                }
            } catch is CancellationError {
                // interrupted
            } catch let error as BLEError {
                output.printError(error.localizedDescription)
                exitCode = error.exitCode
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
        }

        // No external timeout: sub runs until --count / --duration / Ctrl-C.
        if case .interrupted = waitInterruptible(task, semaphore: semaphore) {
            exitCode = 130
        }
        return exitCode
    }

    // MARK: - Interrupt-aware wait

    private enum CommandOutcome { case completed, interrupted, timedOut }

    /// Block the calling (main) thread until the semaphore is signalled, polling
    /// every 50 ms. If a Ctrl-C interrupt arrives, the task is cancelled and we
    /// wait for it to finish before returning `.interrupted`. If a timeout is
    /// provided and the deadline passes before the task finishes, the task is
    /// cancelled and we return `.timedOut`.
    @discardableResult
    private func waitInterruptible(
        _ task: Task<Void, Never>,
        semaphore: DispatchSemaphore,
        timeout: TimeInterval? = nil
    ) -> CommandOutcome {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        commandIsRunning = true
        defer { commandIsRunning = false }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            if interruptRequested {
                interruptRequested = false
                task.cancel()
                _ = semaphore.wait(timeout: .now() + 2.0)
                return .interrupted
            }
            if let dl = deadline, Date() > dl {
                task.cancel()
                _ = semaphore.wait(timeout: .now() + 2.0)
                return .timedOut
            }
        }
        return .completed
    }

    // MARK: - Auto-connect

    /// Ensure a BLE device is connected before running an operation.
    ///
    /// If already connected, returns immediately. Otherwise resolves a target
    /// device from GlobalOptions and connects:
    ///   - `--id`  → direct connect (no scan needed)
    ///   - `--name` / `--service` / `--manufacturer` / `--rssi-min` → scan then pick and connect
    ///   - none of the above → error
    func ensureConnected() -> Int32 {
        var isConnected = false
        let statusSem = DispatchSemaphore(value: 0)
        Task {
            let s = await manager.status()
            isConnected = s.isConnected
            statusSem.signal()
        }
        statusSem.wait()
        if isConnected { return 0 }

        if let id = globals.id {
            return runConnect([id])
        }

        let hasFilters = globals.name != nil
            || !globals.service.isEmpty
            || globals.manufacturer != nil
            || globals.rssiMin != nil
        guard hasFilters else {
            output.printError("not connected — specify a device with --id or --name")
            return BlewExitCode.invalidArguments.code
        }

        let timeout = globals.timeout ?? 5.0
        let code = runScan(["-t", "\(timeout)"])
        if code != 0 { return code }

        guard let device = pickDevice(from: lastScanResults) else {
            return BlewExitCode.notFound.code
        }
        return runConnect([device.identifier])
    }

    /// Pick a single device from candidates according to `globals.pick`.
    /// Returns `nil` (and prints an appropriate error) if the strategy cannot be satisfied.
    private func pickDevice(from candidates: [DiscoveredDevice]) -> DiscoveredDevice? {
        switch globals.pick {
        case .strongest, .first:
            guard let device = candidates.first else {
                output.printError("no devices found")
                return nil
            }
            return device
        case .only:
            if candidates.isEmpty {
                output.printError("no devices found")
                return nil
            }
            if candidates.count > 1 {
                output.printError("--pick only: \(candidates.count) devices found, expected exactly one")
                for d in candidates {
                    let label = d.name.map { "\($0) (\(d.identifier))" } ?? d.identifier
                    output.printError("  \(label)")
                }
                return nil
            }
            return candidates[0]
        }
    }

    // MARK: - Argument parsing helpers

    /// Collect non-flag positional tokens from args. Options listed in
    /// `optionsWithValue` consume their following token and are skipped.
    private func positionalArgs(_ args: [String], optionsWithValue: Set<String>) -> [String] {
        var result: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("-") {
                if optionsWithValue.contains(arg) { skipNext = true }
            } else {
                result.append(arg)
            }
        }
        return result
    }

    private func parseStringOption(_ args: [String], short: String, long: String) -> String? {
        for (i, arg) in args.enumerated() {
            if (arg == short || arg == long) && i + 1 < args.count {
                return args[i + 1]
            }
            if arg.hasPrefix("\(long)=") {
                return String(arg.dropFirst(long.count + 1))
            }
        }
        return nil
    }

    private func parseDoubleOption(_ args: [String], short: String, long: String) -> Double? {
        guard let str = parseStringOption(args, short: short, long: long) else { return nil }
        return Double(str)
    }

    private func parseIntOption(_ args: [String], short: String, long: String) -> Int? {
        guard let str = parseStringOption(args, short: short, long: long) else { return nil }
        return Int(str)
    }
}

// MARK: - Device & characteristic resolution

extension CommandRouter {
    enum DeviceMatch {
        case resolved(DiscoveredDevice)
        case ambiguous([DiscoveredDevice])
        case notFound
    }

    /// Resolve a user-supplied string to a device from the last scan.
    /// Priority: exact UUID → name substring → UUID substring (hyphens stripped).
    func resolveDevice(_ input: String) -> DeviceMatch {
        let lower = input.lowercased()

        // Exact UUID match
        if let exact = lastScanResults.first(where: {
            $0.identifier.lowercased() == lower
        }) {
            return .resolved(exact)
        }

        // Name contains match (case-insensitive)
        let nameMatches = lastScanResults.filter {
            $0.name?.lowercased().contains(lower) == true
        }
        if nameMatches.count == 1 { return .resolved(nameMatches[0]) }
        if nameMatches.count > 1 { return .ambiguous(nameMatches) }

        // UUID substring match — strip hyphens so partial segments like "683687" or
        // "683687E7E810" match anywhere in the UUID, not just at the start.
        let strippedInput = lower.replacingOccurrences(of: "-", with: "")
        guard !strippedInput.isEmpty else { return .notFound }
        let uuidMatches = lastScanResults.filter {
            let strippedId = $0.identifier.lowercased().replacingOccurrences(of: "-", with: "")
            return strippedId.contains(strippedInput)
        }
        if uuidMatches.count == 1 { return .resolved(uuidMatches[0]) }
        if uuidMatches.count > 1 { return .ambiguous(uuidMatches) }

        return .notFound
    }

    enum UUIDMatch {
        case resolved(String)
        case ambiguous([String])
        case notFound
    }

    /// Resolve a partial UUID prefix to a full characteristic UUID.
    func resolveCharacteristic(_ input: String) -> UUIDMatch {
        let lower = input.lowercased()
        let known = manager.knownCharacteristicUUIDs()

        if let exact = known.first(where: { $0.lowercased() == lower }) {
            return .resolved(exact)
        }

        let matches = known.filter { $0.lowercased().hasPrefix(lower) }
        switch matches.count {
        case 0: return .notFound
        case 1: return .resolved(matches[0])
        default: return .ambiguous(matches)
        }
    }

    /// Resolve a partial UUID prefix to a full service UUID.
    func resolveService(_ input: String) -> UUIDMatch {
        let lower = input.lowercased()
        let known = manager.knownServiceUUIDs()

        if let exact = known.first(where: { $0.lowercased() == lower }) {
            return .resolved(exact)
        }

        let matches = known.filter { $0.lowercased().hasPrefix(lower) }
        switch matches.count {
        case 0: return .notFound
        case 1: return .resolved(matches[0])
        default: return .ambiguous(matches)
        }
    }
}

// MARK: - GATT value display helpers

extension CommandRouter {
    /// Split a decoded field string like "Outer.Inner.Leaf: 2026" into
    /// a simplified label ("Leaf") and the raw value string ("2026").
    /// The caller is responsible for applying any visual styling to each part.
    static func splitFieldPart(_ field: String) -> (label: String, value: String) {
        guard let colonRange = field.range(of: ": ") else { return ("", field) }
        let fullName = String(field[field.startIndex..<colonRange.lowerBound])
        let value = String(field[colonRange.upperBound...])
        let shortName = fullName
            .components(separatedBy: ".")
            .last?
            .trimmingCharacters(in: .whitespaces) ?? fullName
        return (shortName, value)
    }
}

// MARK: - RSSI signal bar

extension CommandRouter {
    static func rssiBar(_ rssi: Int, width: Int = 8) -> String {
        let clamped = max(-100, min(-30, rssi))
        let ratio = Double(clamped + 100) / 70.0
        let filled = Int((ratio * Double(width)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }
}

// MARK: - Scan spinner

private final class ScanSpinner {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var frameIndex = 0
    private var timer: DispatchSourceTimer?
    private let startTime = Date()
    private let timeout: Double
    private let lock = NSLock()
    private var _deviceCount = 0

    var deviceCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _deviceCount }
        set { lock.lock(); _deviceCount = newValue; lock.unlock() }
    }

    init(timeout: Double) {
        self.timeout = timeout
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(startTime)
        let frame = Self.frames[frameIndex % Self.frames.count]
        frameIndex += 1
        let count = deviceCount
        let countStr: String
        if count == 0 {
            countStr = ""
        } else {
            countStr = " · \(count) device\(count == 1 ? "" : "s")"
        }
        let line = "\r\u{1B}[K\(frame) Scanning… \(String(format: "%.1f", elapsed))/\(String(format: "%.0f", timeout))s\(countStr)"
        FileHandle.standardError.write(Data(line.utf8))
    }

    func stop() {
        timer?.cancel()
        timer = nil
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }
}

// MARK: - Watch display

/// Renders a live-updating BLE device table in the terminal using ANSI in-place redraws.
/// The table is written to stderr (to keep stdout clean for the final snapshot).
/// A 250 ms timer fires the redraw; device data is updated from the scan Task via `update(devices:)`.
private final class ScanWatchDisplay {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private let formatter: OutputFormatter
    private let startTime = Date()
    private let lock = NSLock()
    private var _devices: [DiscoveredDevice] = []
    private var frameIndex = 0
    private var timer: DispatchSourceTimer?
    /// Number of lines written to stderr on the previous draw cycle.
    private var previousLineCount = 0

    init(formatter: OutputFormatter) {
        self.formatter = formatter
    }

    func update(devices: [DiscoveredDevice]) {
        lock.lock()
        _devices = devices
        lock.unlock()
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        // Erase the in-place content from stderr so the caller can print the final
        // table cleanly to stdout.
        eraseLines(previousLineCount)
    }

    // MARK: - Private

    private func tick() {
        lock.lock()
        let devices = _devices
        lock.unlock()

        let frame = Self.frames[frameIndex % Self.frames.count]
        frameIndex += 1

        let elapsed = Date().timeIntervalSince(startTime)
        let count = devices.count
        let countStr = count == 0 ? "no devices yet" : "\(count) device\(count == 1 ? "" : "s")"
        let header = "\(frame) Scanning \(String(format: "%.0f", elapsed))s  \(countStr)  (Ctrl-C to stop)"

        var lines: [String] = [header]
        if !devices.isEmpty {
            let tableHeaders = ["ID", "Name", "RSSI", "Signal", "Services"]
            let rows: [[String]] = devices.map { d in
                [
                    d.identifier,
                    d.name ?? "(unknown)",
                    "\(d.rssi)",
                    CommandRouter.rssiBar(d.rssi),
                    d.serviceUUIDs.map { BLENames.displayUUID($0, category: .service) }.joined(separator: ", "),
                ]
            }
            let table = formatter.formatTable(headers: tableHeaders, rows: rows)
            lines.append(contentsOf: table.components(separatedBy: "\n"))
        }

        let newLineCount = lines.count

        // Move cursor up by the number of lines drawn previously and clear to end of screen.
        eraseLines(previousLineCount)
        previousLineCount = newLineCount

        let output = lines.joined(separator: "\n") + "\n"
        FileHandle.standardError.write(Data(output.utf8))
    }

    private func eraseLines(_ count: Int) {
        guard count > 0 else { return }
        // Move up `count` lines then clear from cursor to end of screen.
        let escape = "\u{1B}[\(count)A\u{1B}[J"
        FileHandle.standardError.write(Data(escape.utf8))
    }
}

private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
