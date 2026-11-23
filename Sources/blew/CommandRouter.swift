import Foundation
import BLEManager

final class CommandRouter {
    let globals: GlobalOptions
    let manager: BLECentral
    let output: OutputFormatter
    let renderer: OutputRenderer
    let isInteractiveMode: Bool
    var lastScanResults: [DiscoveredDevice] = []
    private var backgroundPeriphTask: Task<Void, Never>?
    private var backgroundSubTasks: [String: Task<Void, Never>] = [:]

    init(globals: GlobalOptions, manager: BLECentral? = nil, isInteractiveMode: Bool = false,
         renderer: OutputRenderer? = nil) {
        self.globals = globals
        self.manager = manager ?? BLECentral.shared
        self.output = OutputFormatter(format: globals.out, verbosity: globals.verbose)
        self.renderer = renderer ?? makeRenderer(format: globals.out, verbosity: globals.verbose)
        self.isInteractiveMode = isInteractiveMode
    }

    /// Execute a semicolon-separated script string. Returns exit code.
    func executeScript(_ script: String, keepGoing: Bool = false, dryRun: Bool = false) -> Int32 {
        let segments = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let commands = segments.filter { !$0.isEmpty }

        if dryRun {
            for (i, cmd) in commands.enumerated() {
                print("[\(i + 1)] \(cmd)")
            }
            return 0
        }

        var firstError: Int32 = 0
        for cmd in commands {
            let result = dispatch(cmd)
            if result.exitCode != 0 {
                if firstError == 0 { firstError = result.exitCode }
                if !keepGoing {
                    return result.exitCode
                }
            }
        }
        return firstError
    }

    /// Parse and dispatch a single command line. Returns CommandResult.
    func dispatch(_ line: String) -> CommandResult {
        let tokens = tokenize(line)
        guard let first = tokens.first else { return CommandResult() }

        let result: CommandResult
        switch first {
        case "scan":
            result = runScan(Array(tokens.dropFirst()))
        case "connect":
            result = runConnect(Array(tokens.dropFirst()))
        case "disconnect":
            result = runDisconnect(Array(tokens.dropFirst()))
        case "status":
            result = runStatus(Array(tokens.dropFirst()))
        case "gatt":
            result = runGATT(Array(tokens.dropFirst()))
        case "read":
            result = runRead(Array(tokens.dropFirst()))
        case "write":
            result = runWrite(Array(tokens.dropFirst()))
        case "sub":
            result = runSub(Array(tokens.dropFirst()), emit: { [self] item in renderer.render(item) })
        case "periph":
            result = runPeriph(Array(tokens.dropFirst()), emit: { [self] item in renderer.render(item) })
        case "nus":
            result = runNUS(Array(tokens.dropFirst()), emit: { [self] item in renderer.render(item) })
        case "sleep":
            result = runSleep(Array(tokens.dropFirst()))
        case "help":
            printHelp()
            return CommandResult()
        default:
            var r = CommandResult()
            r.errors.append("unknown command '\(first)'")
            r.exitCode = BlewExitCode.invalidArguments.code
            renderer.renderResult(r)
            return r
        }

        renderer.renderResult(result)
        return result
    }

    func printHelp() {
        func cmd(_ name: String) -> String { output.bold(name) }
        let targeting = "[-n <name>] [-S <uuid>] [-i <id>]"
        let lines = [
            "Available commands:",
            "  \(cmd("scan")) \(targeting) [-R <dBm>] [-m <mfr>] [-p <strategy>] [-w]",
            "  \(cmd("connect")) \(targeting) [<id>]",
            "  \(cmd("disconnect"))",
            "  \(cmd("status"))",
            "  \(cmd("gatt")) \(cmd("svcs")) \(targeting)",
            "  \(cmd("gatt")) \(cmd("tree")) \(targeting) [-d] [-r]",
            "  \(cmd("gatt")) \(cmd("chars")) \(targeting) [-r] <service>",
            "  \(cmd("gatt")) \(cmd("desc")) \(targeting) <char>",
            "  \(cmd("gatt")) \(cmd("info")) <char>",
            "  \(cmd("read")) \(targeting) [-f <fmt>] <char>",
            "  \(cmd("write")) \(targeting) [-f <fmt>] [-r|-w] <char> <data>",
            "  \(cmd("sub")) \(targeting) [-f <fmt>] [-d <sec>] [-c <n>] [-b] <char>",
            "  \(cmd("sub")) \(cmd("stop")) [<char>]",
            "  \(cmd("sub")) \(cmd("status"))",
            "  \(cmd("periph")) \(cmd("adv")) [-n <name>] [-S <uuid>] [--config <file>]",
            "  \(cmd("periph")) \(cmd("clone")) \(targeting) [--save <file>]",
            "  \(cmd("periph")) \(cmd("stop"))",
            "  \(cmd("periph")) \(cmd("set")) [-f <fmt>] <char> <value>",
            "  \(cmd("periph")) \(cmd("notify")) [-f <fmt>] <char> <value>",
            "  \(cmd("nus")) \(targeting) [-s <text>] [--file <path>] [-e <text>] [-d <sec>] [--pty] [-l <port>] [--reconnect] [-r|-w]",
            "  \(cmd("sleep")) <seconds>",
            "  \(cmd("help"))",
            "  \(cmd("quit"))/\(cmd("exit"))",
        ]
        print(lines.joined(separator: "\n"))
    }

    func tokenize(_ line: String) -> [String] {
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

    func runScan(_ args: [String]) -> CommandResult {
        let scanOpts: Set<String> = ["-n", "--name", "-R", "--rssi-min", "-t", "--timeout", "-S", "--service", "-m", "--manufacturer", "-p", "--pick", "-i", "--id"]
        let args = expandArgs(args, optionsWithValue: scanOpts)
        let watchMode = hasFlag(args, short: "-w", long: "--watch", optionsWithValue: scanOpts)
        let nameFilter = parseStringOption(args, short: "-n", long: "--name", optionsWithValue: scanOpts)
        let rssiMin = parseIntOption(args, short: "-R", long: "--rssi-min", optionsWithValue: scanOpts)

        if watchMode {
            return runScanWatch(nameFilter: nameFilter, rssiMin: rssiMin)
        }

        let scanTimeout = parseDoubleOption(args, short: "-t", long: "--timeout", optionsWithValue: scanOpts) ?? globals.timeout ?? 5.0
        guard Self.isValidDuration(scanTimeout) else {
            var result = CommandResult()
            result.errors.append("invalid timeout '\(scanTimeout)' (use 0 to \(Int(Self.maxDuration)) seconds)")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        let interactive = isatty(fileno(stderr)) != 0
        let spinner: ScanSpinner? = interactive ? ScanSpinner(timeout: scanTimeout) : nil
        if !interactive {
            renderer.renderInfo("scanning for \(scanTimeout)s...")
        }
        spinner?.start()

        let semaphore = DispatchSemaphore(value: 0)
        var deviceMap: [String: DiscoveredDevice] = [:]
        var result = CommandResult()

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
                result.errors.append("\(error)")
                result.exitCode = BlewExitCode.operationFailed.code
            }
        }

        let outcome = waitInterruptible(task, semaphore: semaphore)
        spinner?.stop()

        if case .interrupted = outcome { result.exitCode = 130; return result }

        if result.exitCode != 0 { return result }

        let devices = Array(deviceMap.values)
        if devices.isEmpty {
            result.errors.append("no devices found")
            result.exitCode = BlewExitCode.notFound.code
            return result
        }

        let sorted = devices.sorted { $0.rssi > $1.rssi }
        lastScanResults = sorted

        let deviceRows = sorted.map { d in
            DeviceRow(
                id: d.identifier,
                name: d.name,
                rssi: d.rssi,
                serviceUUIDs: d.serviceUUIDs,
                serviceDisplayNames: d.serviceUUIDs.map { BLENames.displayUUID($0, category: .service) }
            )
        }
        result.output.append(.devices(deviceRows))
        return result
    }

    private func runScanWatch(nameFilter: String?, rssiMin: Int?) -> CommandResult {
        if output.format == .kv {
            return runScanWatchKV(nameFilter: nameFilter, rssiMin: rssiMin)
        }

        guard isatty(fileno(stdout)) != 0 else {
            var r = CommandResult()
            r.errors.append("scan --watch in text mode requires an interactive terminal; use -o kv for piped output")
            r.exitCode = BlewExitCode.invalidArguments.code
            return r
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
                scanError = BlewExitCode.operationFailed.code
                renderer.renderError("\(error)")
            }
        }

        let outcome = waitInterruptible(task, semaphore: semaphore)
        display.stop()

        var result = CommandResult()
        let sorted = deviceMap.values.sorted { $0.rssi > $1.rssi }
        lastScanResults = sorted

        if case .interrupted = outcome {
            if !sorted.isEmpty {
                let rows = sorted.map { d in
                    DeviceRow(id: d.identifier, name: d.name, rssi: d.rssi,
                              serviceUUIDs: d.serviceUUIDs,
                              serviceDisplayNames: d.serviceUUIDs.map { BLENames.displayUUID($0, category: .service) })
                }
                result.output.append(.devices(rows))
            }
            result.exitCode = 130
            return result
        }

        if scanError != 0 { result.exitCode = scanError; return result }

        if sorted.isEmpty {
            result.errors.append("no devices found")
            result.exitCode = BlewExitCode.notFound.code
            return result
        }
        let rows = sorted.map { d in
            DeviceRow(id: d.identifier, name: d.name, rssi: d.rssi,
                      serviceUUIDs: d.serviceUUIDs,
                      serviceDisplayNames: d.serviceUUIDs.map { BLENames.displayUUID($0, category: .service) })
        }
        result.output.append(.devices(rows))
        return result
    }

    private func runScanWatchKV(nameFilter: String?, rssiMin: Int?) -> CommandResult {
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
                    let row = DeviceRow(id: d.identifier, name: d.name, rssi: d.rssi,
                                        serviceUUIDs: d.serviceUUIDs,
                                        serviceDisplayNames: d.serviceUUIDs.map { BLENames.displayUUID($0, category: .service) })
                    renderer.render(.devices([row]))
                }
            } catch is CancellationError {
                // normal exit
            } catch {
                renderer.renderError("\(error)")
                scanError = BlewExitCode.operationFailed.code
            }
        }

        var result = CommandResult()
        let outcome = waitInterruptible(task, semaphore: semaphore)
        if case .interrupted = outcome {
            lastScanResults = deviceMap.values.sorted { $0.rssi > $1.rssi }
            result.exitCode = 130
            return result
        }
        if scanError != 0 { result.exitCode = scanError; return result }
        lastScanResults = deviceMap.values.sorted { $0.rssi > $1.rssi }
        return result
    }

    func runConnect(_ args: [String]) -> CommandResult {
        let positional = positionalArgs(args, optionsWithValue: Self.targetingOptionsWithValue)
        let deviceId = positional.first ?? parseStringOption(args, short: "-i", long: "--id", optionsWithValue: Self.targetingOptionsWithValue)
        let connectTimeout = globals.timeout ?? 10.0

        guard let rawInput = deviceId else {
            return ensureConnected(args: args, optionsWithValue: Self.targetingOptionsWithValue)
        }

        var result = CommandResult()

        let resolved = resolveDevice(rawInput)
        if case .ambiguous(let matches) = resolved {
            result.errors.append("ambiguous device '\(rawInput)' -- matches:")
            for d in matches {
                let label = d.name.map { "\($0) (\(d.identifier))" } ?? d.identifier
                result.errors.append("  \(label)")
            }
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        let targetId: String
        if case .resolved(let device) = resolved {
            let label = device.name.map { "\($0) (\(device.identifier))" } ?? device.identifier
            result.infos.append("resolved '\(rawInput)' -> \(label)")
            targetId = device.identifier
        } else {
            targetId = rawInput
        }

        result.infos.append("connecting to \(targetId)...")

        let semaphore = DispatchSemaphore(value: 0)

        let task = Task {
            defer { semaphore.signal() }
            do {
                try await manager.connect(deviceId: targetId, timeout: connectTimeout)
                result.infos.append("connected to \(targetId)")
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch let error as BLEError {
                result.errors.append(error.localizedDescription)
                result.exitCode = error.exitCode
            } catch {
                result.errors.append("\(error)")
                result.exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(task, semaphore: semaphore, timeout: connectTimeout) {
        case .completed: break
        case .interrupted: result.exitCode = 130
        case .timedOut:
            result.errors.append("connection timed out")
            result.exitCode = BlewExitCode.timeout.code
        }
        return result
    }

    func runDisconnect(_ args: [String]) -> CommandResult {
        var result = CommandResult()
        let semaphore = DispatchSemaphore(value: 0)

        let task = Task {
            defer { semaphore.signal() }
            do {
                try await manager.disconnect()
                result.infos.append("disconnected")
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch let error as BLEError {
                result.errors.append(error.localizedDescription)
                result.exitCode = error.exitCode
            } catch {
                result.errors.append("\(error)")
                result.exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(task, semaphore: semaphore, timeout: globals.timeout ?? 5.0) {
        case .completed: break
        case .interrupted: result.exitCode = 130
        case .timedOut:
            result.errors.append("disconnect timed out")
            result.exitCode = BlewExitCode.timeout.code
        }
        return result
    }

    func runStatus(_ args: [String]) -> CommandResult {
        var result = CommandResult()
        let semaphore = DispatchSemaphore(value: 0)

        let task = Task {
            defer { semaphore.signal() }
            let status = await manager.status()
            result.output.append(.connectionStatus(status))
        }

        waitInterruptible(task, semaphore: semaphore)
        return result
    }

    func runSleep(_ args: [String]) -> CommandResult {
        var result = CommandResult()
        guard let raw = args.first, let seconds = Double(raw) else {
            result.errors.append("sleep requires a numeric argument (seconds; 0 = infinite)")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }
        guard Self.isValidDuration(seconds) else {
            result.errors.append("sleep duration must be 0 to \(Int(Self.maxDuration)) seconds")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        let semaphore = DispatchSemaphore(value: 0)

        let task = Task {
            defer { semaphore.signal() }
            do {
                if seconds == 0 {
                    while true {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                } else {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            } catch {}
        }

        if case .interrupted = waitInterruptible(task, semaphore: semaphore) {
            result.exitCode = 130
        }
        return result
    }

    func runGATT(_ args: [String]) -> CommandResult {
        let targetingOpts = Self.targetingOptionsWithValue
        let args = expandArgs(args, optionsWithValue: targetingOpts)
        guard let sub = positionalArgs(args, optionsWithValue: targetingOpts).first else {
            var result = CommandResult()
            result.errors.append("missing subcommand")
            result.output.append(.message("Usage: gatt <svcs|tree|chars|desc|info>"))
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        if sub == "info" {
            let positionals = positionalArgs(args, optionsWithValue: targetingOpts).dropFirst()
            guard let charInput = positionals.first else {
                var result = CommandResult()
                result.errors.append("missing characteristic UUID")
                result.exitCode = BlewExitCode.invalidArguments.code
                return result
            }
            return runGATTInfo(charInput)
        }

        let connectResult = ensureConnected(args: args, optionsWithValue: targetingOpts)
        guard connectResult.exitCode == 0 else { return connectResult }

        var result = CommandResult()
        let semaphore = DispatchSemaphore(value: 0)

        let task = Task {
            defer { semaphore.signal() }
            do {
                switch sub {
                case "svcs":
                    let services = try await manager.discoverServices()
                    let rows = services.map { svc in
                        ServiceRow(uuid: svc.uuid, name: BLENames.name(for: svc.uuid, category: .service), isPrimary: svc.isPrimary)
                    }
                    result.output.append(.services(rows))

                case "tree":
                    let includeDescriptors = args.contains("-d") || args.contains("--descriptors")
                    let includeValues = args.contains("-r") || args.contains("--read")
                    let tree = try await manager.discoverTree(includeDescriptors: includeDescriptors)
                    var treeServices: [GATTTreeService] = []
                    for service in tree {
                        var treeChars: [GATTTreeCharacteristic] = []
                        for char in service.characteristics {
                            let charName = BLENames.name(for: char.uuid, category: .characteristic)
                            var value: String? = nil
                            var valueFields: [LabeledValue]? = nil

                            if includeValues && char.properties.contains("read") {
                                do {
                                    let data = try await manager.readCharacteristic(char.uuid)
                                    let decoded = GATTDecoder.decode(data, uuid: char.uuid)
                                        ?? DataFormatter.format(data, as: "hex")
                                    let parts = decoded.components(separatedBy: " | ")
                                    if parts.count > 1 {
                                        valueFields = parts.map { Self.splitFieldPart($0) }
                                    } else {
                                        value = decoded
                                    }
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    value = "(read error)"
                                }
                            }

                            let descRows = char.descriptors.map { desc in
                                DescriptorRow(uuid: desc.uuid, name: BLENames.name(for: desc.uuid, category: .descriptor))
                            }
                            treeChars.append(GATTTreeCharacteristic(
                                uuid: char.uuid, name: charName,
                                properties: char.properties,
                                value: value, valueFields: valueFields,
                                descriptors: descRows
                            ))
                        }
                        treeServices.append(GATTTreeService(
                            uuid: service.uuid,
                            name: BLENames.name(for: service.uuid, category: .service),
                            characteristics: treeChars
                        ))
                    }
                    result.output.append(.gattTree(treeServices))

                case "chars":
                    let charsOpts = Self.targetingOptionsWithValue
                    let charsPositional = positionalArgs(args, optionsWithValue: charsOpts).dropFirst()
                    guard let svcInput = charsPositional.first else {
                        result.errors.append("missing service UUID")
                        result.exitCode = BlewExitCode.invalidArguments.code
                        return
                    }
                    let svcUUID: String
                    switch resolveService(svcInput) {
                    case .resolved(let uuid): svcUUID = uuid
                    case .ambiguous(let uuids):
                        result.errors.append("ambiguous service '\(svcInput)' -- matches: \(uuids.joined(separator: ", "))")
                        result.exitCode = BlewExitCode.invalidArguments.code
                        return
                    case .notFound: svcUUID = svcInput
                    }
                    let includeValues = args.contains("-r") || args.contains("--read")
                    let chars = try await manager.discoverCharacteristics(forService: svcUUID)
                    var charRows: [CharacteristicRow] = []
                    for char in chars {
                        let name = BLENames.name(for: char.uuid, category: .characteristic)
                        var value: String? = nil
                        var valueFields: [LabeledValue]? = nil
                        if includeValues && char.properties.contains("read") {
                            do {
                                let data = try await manager.readCharacteristic(char.uuid)
                                let decoded = GATTDecoder.decode(data, uuid: char.uuid)
                                    ?? DataFormatter.format(data, as: "hex")
                                let parts = decoded.components(separatedBy: " | ")
                                if parts.count > 1 {
                                    valueFields = parts.map { Self.splitFieldPart($0) }
                                } else {
                                    value = decoded
                                }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                value = "(read error)"
                            }
                        }
                        charRows.append(CharacteristicRow(uuid: char.uuid, name: name,
                                                          properties: char.properties,
                                                          value: value, valueFields: valueFields))
                    }
                    result.output.append(.characteristics(charRows))

                case "desc":
                    let descOpts = Self.targetingOptionsWithValue
                    let descPositional = positionalArgs(args, optionsWithValue: descOpts).dropFirst()
                    guard let charInput = descPositional.first else {
                        result.errors.append("missing characteristic UUID")
                        result.exitCode = BlewExitCode.invalidArguments.code
                        return
                    }
                    let charUUID: String
                    switch resolveCharacteristic(charInput) {
                    case .resolved(let uuid): charUUID = uuid
                    case .ambiguous(let uuids):
                        result.errors.append("ambiguous characteristic '\(charInput)' -- matches: \(uuids.joined(separator: ", "))")
                        result.exitCode = BlewExitCode.invalidArguments.code
                        return
                    case .notFound: charUUID = charInput
                    }
                    let descs = try await manager.discoverDescriptors(forCharacteristic: charUUID)
                    let rows = descs.map { desc in
                        DescriptorRow(uuid: desc.uuid, name: BLENames.name(for: desc.uuid, category: .descriptor))
                    }
                    result.output.append(.descriptors(rows))

                default:
                    result.errors.append("unknown gatt subcommand '\(sub)'")
                    result.output.append(.message("Usage: gatt <svcs|tree|chars|desc|info>"))
                    result.exitCode = BlewExitCode.invalidArguments.code
                }
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch let error as BLEError {
                result.errors.append(error.localizedDescription)
                result.exitCode = error.exitCode
            } catch {
                result.errors.append("\(error)")
                result.exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(task, semaphore: semaphore, timeout: globals.timeout ?? 10.0) {
        case .completed: break
        case .interrupted: result.exitCode = 130
        case .timedOut:
            result.errors.append("operation timed out")
            result.exitCode = BlewExitCode.timeout.code
        }
        return result
    }

    private func runGATTInfo(_ charInput: String) -> CommandResult {
        var result = CommandResult()
        guard let info = GATTDecoder.info(for: charInput) else {
            result.errors.append("no Bluetooth SIG definition found for '\(charInput)'")
            result.exitCode = BlewExitCode.notFound.code
            return result
        }

        result.output.append(.characteristicInfo(GATTCharInfo(
            uuid: info.uuid, name: info.name,
            description: info.description, fields: info.fields
        )))
        return result
    }

    func runRead(_ args: [String]) -> CommandResult {
        let readOpts = Self.targetingOptionsWithValue.union(["-f", "--format"])
        let connectResult = ensureConnected(args: args, optionsWithValue: readOpts)
        guard connectResult.exitCode == 0 else { return connectResult }

        guard let charInput = positionalArgs(args, optionsWithValue: readOpts).first else {
            var result = CommandResult()
            result.errors.append("missing characteristic UUID")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }
        var result = CommandResult()
        let charUUID: String
        switch resolveCharacteristic(charInput) {
        case .resolved(let uuid): charUUID = uuid
        case .ambiguous(let uuids):
            result.errors.append("ambiguous characteristic '\(charInput)' -- matches: \(uuids.joined(separator: ", "))")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        case .notFound: charUUID = charInput
        }
        let fmt = parseStringOption(args, short: "-f", long: "--format", optionsWithValue: readOpts) ?? "hex"

        let semaphore = DispatchSemaphore(value: 0)

        let task = Task {
            defer { semaphore.signal() }
            do {
                let data = try await manager.readCharacteristic(charUUID)
                let formatted = DataFormatter.format(data, as: fmt)
                let name = BLENames.name(for: charUUID, category: .characteristic)
                result.output.append(.readValue(ReadResult(char: charUUID, name: name, value: formatted, format: fmt)))
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch let error as BLEError {
                result.errors.append(error.localizedDescription)
                result.exitCode = error.exitCode
            } catch {
                result.errors.append("\(error)")
                result.exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(task, semaphore: semaphore, timeout: globals.timeout ?? 5.0) {
        case .completed: break
        case .interrupted: result.exitCode = 130
        case .timedOut:
            result.errors.append("read timed out")
            result.exitCode = BlewExitCode.timeout.code
        }
        return result
    }

    func runWrite(_ args: [String]) -> CommandResult {
        let writeOpts = Self.targetingOptionsWithValue.union(["-f", "--format"])
        let args = expandArgs(args, optionsWithValue: writeOpts)
        let connectResult = ensureConnected(args: args, optionsWithValue: writeOpts)
        guard connectResult.exitCode == 0 else { return connectResult }

        var result = CommandResult()
        let positional = positionalArgs(args, optionsWithValue: writeOpts)
        guard positional.count >= 2 else {
            if positional.isEmpty {
                result.errors.append("missing characteristic UUID and data")
            } else {
                result.errors.append("missing data to write")
            }
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }
        let charInput = positional[0]
        let dataStr = positional[1]
        let charUUID: String
        switch resolveCharacteristic(charInput) {
        case .resolved(let uuid): charUUID = uuid
        case .ambiguous(let uuids):
            result.errors.append("ambiguous characteristic '\(charInput)' -- matches: \(uuids.joined(separator: ", "))")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        case .notFound: charUUID = charInput
        }
        let fmt = parseStringOption(args, short: "-f", long: "--format", optionsWithValue: writeOpts) ?? "hex"
        let withResponse = hasFlag(args, short: "-r", long: "--with-response", optionsWithValue: writeOpts)
        let withoutResponse = hasFlag(args, short: "-w", long: "--without-response", optionsWithValue: writeOpts)

        guard let data = DataFormatter.parse(dataStr, as: fmt) else {
            result.errors.append("invalid data '\(dataStr)' for format '\(fmt)'")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
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

        let task = Task {
            defer { semaphore.signal() }
            do {
                try await manager.writeCharacteristic(charUUID, data: data, type: writeType)
                result.infos.append("written to \(BLENames.displayUUID(charUUID, category: .characteristic))")
                result.output.append(.writeSuccess(char: charUUID, name: BLENames.name(for: charUUID, category: .characteristic)))
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch let error as BLEError {
                result.errors.append(error.localizedDescription)
                result.exitCode = error.exitCode
            } catch {
                result.errors.append("\(error)")
                result.exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(task, semaphore: semaphore, timeout: globals.timeout ?? 5.0) {
        case .completed: break
        case .interrupted: result.exitCode = 130
        case .timedOut:
            result.errors.append("write timed out")
            result.exitCode = BlewExitCode.timeout.code
        }
        return result
    }

    func runSub(_ args: [String], emit: @escaping @Sendable (CommandOutput) -> Void = { _ in }) -> CommandResult {
        let subOpts = Self.targetingOptionsWithValue.union(["-f", "--format", "-d", "--duration", "-c", "--count"])
        let args = expandArgs(args, optionsWithValue: subOpts)
        if let first = args.first {
            switch first {
            case "stop":   return runSubStop(Array(args.dropFirst()))
            case "status": return runSubStatus(Array(args.dropFirst()))
            default: break
            }
        }

        var result = CommandResult()
        let durationText = parseStringOption(args, short: "-d", long: "--duration", optionsWithValue: subOpts)
        let duration = durationText.flatMap(Double.init)
        if let durationText, !(duration.map(Self.isValidDuration) ?? false) {
            result.errors.append("invalid duration '\(durationText)' (use 0 to \(Int(Self.maxDuration)) seconds)")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        let connectResult = ensureConnected(args: args, optionsWithValue: subOpts)
        guard connectResult.exitCode == 0 else { return connectResult }
        let background = args.contains("--bg") || args.contains("-b")
        let positionals = positionalArgs(args.filter { $0 != "--bg" && $0 != "-b" }, optionsWithValue: subOpts)
        guard let charInput = positionals.first else {
            result.errors.append("missing characteristic UUID")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }
        let charUUID: String
        switch resolveCharacteristic(charInput) {
        case .resolved(let uuid): charUUID = uuid
        case .ambiguous(let uuids):
            result.errors.append("ambiguous characteristic '\(charInput)' -- matches: \(uuids.joined(separator: ", "))")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        case .notFound: charUUID = charInput
        }
        let fmt = parseStringOption(args, short: "-f", long: "--format", optionsWithValue: subOpts) ?? "hex"
        let maxCount = parseIntOption(args, short: "-c", long: "--count", optionsWithValue: subOpts)

        if background {
            guard isInteractiveMode else {
                result.errors.append("-b is only available in interactive mode")
                result.exitCode = BlewExitCode.invalidArguments.code
                return result
            }
            backgroundSubTasks[charUUID]?.cancel()
            let capturedRenderer = self.renderer
            backgroundSubTasks[charUUID] = Task {
                do {
                    let stream = try await manager.subscribe(characteristicUUID: charUUID)
                    await Self.forEachNotification(stream, maxCount: maxCount, duration: duration) { data in
                        capturedRenderer.renderLive("[\(charUUID)] \(DataFormatter.format(data, as: fmt))")
                    }
                } catch is CancellationError {
                    // stopped
                } catch let error as BLEError {
                    capturedRenderer.renderLive("sub error [\(charUUID)]: \(error.localizedDescription)")
                } catch {
                    capturedRenderer.renderLive("sub error [\(charUUID)]: \(error)")
                }
                backgroundSubTasks.removeValue(forKey: charUUID)
            }
            let displayUUID = BLENames.displayUUID(charUUID, category: .characteristic)
            result.output.append(.message("Subscribing to \(displayUUID) in background. Use 'sub stop \(charUUID)' to stop."))
            return result
        }

        // Foreground subscription: streaming command, emits each notification to caller
        let semaphore = DispatchSemaphore(value: 0)

        let task = Task {
            defer { semaphore.signal() }
            do {
                let stream = try await manager.subscribe(characteristicUUID: charUUID)
                let charName = BLENames.name(for: charUUID, category: .characteristic)
                await Self.forEachNotification(stream, maxCount: maxCount, duration: duration) { data in
                    let ts = ISO8601DateFormatter.shared.string(from: Date())
                    emit(.notification(NotificationValue(timestamp: ts, char: charUUID, name: charName,
                                                         value: DataFormatter.format(data, as: fmt))))
                }
            } catch is CancellationError {
                // interrupted
            } catch let error as BLEError {
                result.errors.append(error.localizedDescription)
                result.exitCode = error.exitCode
            } catch {
                result.errors.append("\(error)")
                result.exitCode = BlewExitCode.operationFailed.code
            }
        }

        if case .interrupted = waitInterruptible(task, semaphore: semaphore) {
            result.exitCode = 130
        }
        return result
    }

    func runSubStop(_ args: [String]) -> CommandResult {
        var result = CommandResult()
        if let charInput = args.first {
            let charUUID: String
            switch resolveCharacteristic(charInput) {
            case .resolved(let uuid): charUUID = uuid
            case .ambiguous(let uuids):
                result.errors.append("ambiguous characteristic '\(charInput)' -- matches: \(uuids.joined(separator: ", "))")
                result.exitCode = BlewExitCode.invalidArguments.code
                return result
            case .notFound: charUUID = charInput
            }
            guard backgroundSubTasks[charUUID] != nil else {
                result.errors.append("no background subscription for '\(charUUID)'")
                result.exitCode = BlewExitCode.notFound.code
                return result
            }
            backgroundSubTasks[charUUID]?.cancel()
            backgroundSubTasks.removeValue(forKey: charUUID)
            result.output.append(.message("Stopped subscription for \(BLENames.displayUUID(charUUID, category: .characteristic))."))
        } else {
            guard !backgroundSubTasks.isEmpty else {
                result.output.append(.message("No active background subscriptions."))
                return result
            }
            for (_, task) in backgroundSubTasks { task.cancel() }
            backgroundSubTasks.removeAll()
            result.output.append(.message("Stopped all background subscriptions."))
        }
        return result
    }

    func runSubStatus(_ args: [String]) -> CommandResult {
        var result = CommandResult()
        let uuids = backgroundSubTasks.keys.sorted()
        result.output.append(.subscriptionList(uuids))
        return result
    }

    /// The longest `-d` a command accepts: a year, well inside what the
    /// nanosecond sleep conversion can hold.
    static let maxDuration: TimeInterval = 365 * 24 * 3600

    static func isValidDuration(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds >= 0 && seconds <= maxDuration
    }

    /// Pass each notification of `stream` to `handle` until `maxCount` have
    /// arrived, `duration` seconds have passed (whether or not any arrive) or
    /// the stream ends. Ending the iteration ends the subscription.
    static func forEachNotification(_ stream: AsyncStream<Data>, maxCount: Int?, duration: TimeInterval?,
                                    _ handle: @escaping @Sendable (Data) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var count = 0
                for await data in stream {
                    handle(data)
                    count += 1
                    if let maxCount, count >= maxCount { return }
                }
            }
            if let duration {
                group.addTask { try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Interrupt-aware wait

    enum CommandOutcome { case completed, interrupted, timedOut }

    /// Block the calling (main) thread until the semaphore is signalled, polling
    /// every 50 ms. If a Ctrl-C interrupt arrives, the task is cancelled and we
    /// wait for it to finish before returning `.interrupted`. If a timeout is
    /// provided and the deadline passes before the task finishes, the task is
    /// cancelled and we return `.timedOut`.
    @discardableResult
    func waitInterruptible(
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
    /// device from the args array and connects:
    ///   - `-i`/`--id`  → direct connect (no scan needed)
    ///   - `-n`/`--name` / `-S`/`--service` / `-m`/`--manufacturer` / `-R`/`--rssi-min` → scan then pick and connect
    ///   - none of the above → error
    /// Options of the device-targeting group that take a value.
    static let targetingOptionsWithValue: Set<String> = [
        "-i", "--id", "-n", "--name", "-S", "--service", "-m", "--manufacturer", "-R", "--rssi-min", "-p", "--pick",
    ]

    /// `optionsWithValue` lists the calling command's options that take a
    /// value, so their values are never read as targeting options.
    func ensureConnected(args: [String], optionsWithValue: Set<String>) -> CommandResult {
        var isConnected = false
        let statusSem = DispatchSemaphore(value: 0)
        Task {
            let s = await manager.status()
            isConnected = s.isConnected
            statusSem.signal()
        }
        statusSem.wait()
        if isConnected { return CommandResult() }

        if let id = parseStringOption(args, short: "-i", long: "--id", optionsWithValue: optionsWithValue) {
            return runConnect([id])
        }

        let name = parseStringOption(args, short: "-n", long: "--name", optionsWithValue: optionsWithValue)
        let services = parseAllStringOptions(args, short: "-S", long: "--service", optionsWithValue: optionsWithValue)
        let manufacturer = parseIntOption(args, short: "-m", long: "--manufacturer", optionsWithValue: optionsWithValue)
        let rssiMin = parseIntOption(args, short: "-R", long: "--rssi-min", optionsWithValue: optionsWithValue)

        let hasFilters = name != nil || !services.isEmpty || manufacturer != nil || rssiMin != nil
        guard hasFilters else {
            var result = CommandResult()
            result.errors.append("not connected -- specify a device with --id or --name")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        let timeout = globals.timeout ?? 5.0
        var scanArgs = ["-t", "\(timeout)"]
        if let n = name { scanArgs += ["-n", n] }
        for s in services { scanArgs += ["-S", s] }
        if let m = manufacturer { scanArgs += ["-m", "\(m)"] }
        if let r = rssiMin { scanArgs += ["-R", "\(r)"] }

        let scanResult = runScan(scanArgs)
        if scanResult.exitCode != 0 { return scanResult }

        let pick = parsePickStrategy(args, optionsWithValue: optionsWithValue)
        guard let device = pickDevice(from: lastScanResults, pick: pick) else {
            var result = CommandResult()
            result.exitCode = BlewExitCode.notFound.code
            return result
        }
        return runConnect([device.identifier])
    }

    /// Pick a single device from candidates according to the given strategy.
    /// Returns `nil` (and prints an appropriate error) if the strategy cannot be satisfied.
    private func pickDevice(from candidates: [DiscoveredDevice], pick: PickStrategy = .strongest) -> DiscoveredDevice? {
        switch pick {
        case .strongest, .first:
            guard let device = candidates.first else {
                renderer.renderError("no devices found")
                return nil
            }
            return device
        case .only:
            if candidates.isEmpty {
                renderer.renderError("no devices found")
                return nil
            }
            if candidates.count > 1 {
                renderer.renderError("--pick only: \(candidates.count) devices found, expected exactly one")
                for d in candidates {
                    let label = d.name.map { "\($0) (\(d.identifier))" } ?? d.identifier
                    renderer.renderError("  \(label)")
                }
                return nil
            }
            return candidates[0]
        }
    }

    private func parsePickStrategy(_ args: [String], optionsWithValue: Set<String>) -> PickStrategy {
        guard let raw = parseStringOption(args, short: "-p", long: "--pick", optionsWithValue: optionsWithValue) else { return .strongest }
        return PickStrategy(rawValue: raw) ?? .strongest
    }

    // MARK: - Argument parsing helpers

    /// Expand combined single-dash short flags into individual flags.
    /// For example, `["-dr"]` becomes `["-d", "-r"]`. Long flags (`--foo`)
    /// and single-char flags (`-d`) are passed through unchanged.
    func expandArgs(_ args: [String], optionsWithValue: Set<String> = []) -> [String] {
        var result: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext {
                result.append(arg)
                skipNext = false
                continue
            }
            if arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.count > 2 {
                for ch in arg.dropFirst() {
                    result.append("-\(ch)")
                }
            } else {
                result.append(arg)
            }
            if let last = result.last, optionsWithValue.contains(last) {
                skipNext = true
            }
        }
        return result
    }

    /// Collect non-flag positional tokens from args. Options listed in
    /// `optionsWithValue` consume their following token and are skipped.
    func positionalArgs(_ args: [String], optionsWithValue: Set<String>) -> [String] {
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

    /// The options at option positions of `args`, in order, each with its
    /// value. An option in `optionsWithValue` takes the next token whatever it
    /// looks like (nil when there is none), `--long=value` carries its own,
    /// and any other option is a flag. Positional tokens are skipped. Every
    /// option lookup goes through this one walk, so a value is never read as
    /// an option.
    static func scanOptions(_ args: [String], optionsWithValue: Set<String>) -> [(name: String, value: String?)] {
        var options: [(name: String, value: String?)] = []
        var tokens = args[...]
        while let arg = tokens.popFirst() {
            guard arg.hasPrefix("-") else { continue }
            if optionsWithValue.contains(arg) {
                options.append((arg, tokens.popFirst()))
            } else if arg.hasPrefix("--"), let equals = arg.firstIndex(of: "=") {
                options.append((String(arg[..<equals]), String(arg[arg.index(after: equals)...])))
            } else {
                options.append((arg, nil))
            }
        }
        return options
    }

    /// The first value of `short` or `long`. `optionsWithValue` lists the
    /// command's options that take a value, so their values are skipped.
    func parseStringOption(_ args: [String], short: String, long: String, optionsWithValue: Set<String>) -> String? {
        parseAllStringOptions(args, short: short, long: long, optionsWithValue: optionsWithValue).first
    }

    func parseDoubleOption(_ args: [String], short: String, long: String, optionsWithValue: Set<String>) -> Double? {
        parseStringOption(args, short: short, long: long, optionsWithValue: optionsWithValue).flatMap(Double.init)
    }

    func parseIntOption(_ args: [String], short: String, long: String, optionsWithValue: Set<String>) -> Int? {
        parseStringOption(args, short: short, long: long, optionsWithValue: optionsWithValue).flatMap { Int($0) }
    }

    /// Collect all values for a repeatable option (e.g. `-S uuid1 -S uuid2`).
    func parseAllStringOptions(_ args: [String], short: String, long: String, optionsWithValue: Set<String>) -> [String] {
        Self.scanOptions(args, optionsWithValue: optionsWithValue.union([short, long]))
            .compactMap { $0.name == short || $0.name == long ? $0.value : nil }
    }

    /// Whether a flag named `short` or `long` is at an option position.
    func hasFlag(_ args: [String], short: String, long: String, optionsWithValue: Set<String>) -> Bool {
        Self.scanOptions(args, optionsWithValue: optionsWithValue)
            .contains { ($0.name == short || $0.name == long) && $0.value == nil }
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
    static func splitFieldPart(_ field: String) -> LabeledValue {
        guard let colonRange = field.range(of: ": ") else { return LabeledValue(label: "", value: field) }
        let fullName = String(field[field.startIndex..<colonRange.lowerBound])
        let value = String(field[colonRange.upperBound...])
        let shortName = fullName
            .components(separatedBy: ".")
            .last?
            .trimmingCharacters(in: .whitespaces) ?? fullName
        return LabeledValue(label: shortName, value: value)
    }
}

// MARK: - Peripheral commands

extension CommandRouter {
    func runPeriph(_ args: [String], emit: @escaping @Sendable (CommandOutput) -> Void = { _ in }) -> CommandResult {
        guard let sub = args.first else {
            var result = CommandResult()
            result.errors.append("missing subcommand")
            result.output.append(.message("Usage: periph <adv|clone|stop|set|notify|status>"))
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        switch sub {
        case "adv":
            return runPeriphAdv(Array(args.dropFirst()), emit: emit)
        case "clone":
            return runPeriphClone(Array(args.dropFirst()), emit: emit)
        case "stop":
            return runPeriphStop(Array(args.dropFirst()))
        case "set":
            return runPeriphSet(Array(args.dropFirst()))
        case "notify":
            return runPeriphNotify(Array(args.dropFirst()))
        case "status":
            return runPeriphStatus(Array(args.dropFirst()))
        default:
            var result = CommandResult()
            result.errors.append("unknown periph subcommand '\(sub)'")
            result.output.append(.message("Usage: periph <adv|clone|stop|set|notify|status>"))
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }
    }

    func runPeriphAdv(_ args: [String], emit: @escaping @Sendable (CommandOutput) -> Void = { _ in }) -> CommandResult {
        var result = CommandResult()
        let advOpts: Set<String> = ["-c", "--config", "-n", "--name", "-S", "--service"]
        let configPath = parseStringOption(args, short: "-c", long: "--config", optionsWithValue: advOpts)
        let serviceArgs = parseAllStringOptions(args, short: "-S", long: "--service", optionsWithValue: advOpts)
        let nameArg = parseStringOption(args, short: "-n", long: "--name", optionsWithValue: advOpts)

        var serviceUUIDs: [BLEUUID]
        var services: [ServiceDefinition] = []
        var advName: String
        var initialValues: [BLEUUID: Data] = [:]

        do {
            serviceUUIDs = try serviceArgs.map { try BLEUUID(parsing: $0) }
            if let path = configPath {
                let config = try PeripheralConfig.load(from: path)
                initialValues = try config.resolvedInitialValues()
                services = config.services
                advName = nameArg ?? config.name ?? "blew"
                if serviceUUIDs.isEmpty { serviceUUIDs = config.services.map { $0.uuid } }
            } else {
                advName = nameArg ?? "blew"
                services = serviceUUIDs.map { uuid in
                    ServiceDefinition(uuid: uuid, primary: true, characteristics: [])
                }
            }
        } catch {
            result.errors.append(error.localizedDescription)
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        if services.isEmpty && serviceUUIDs.isEmpty {
            result.errors.append("no services defined -- use --config <file> or -S <uuid>")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        let peripheral = BLEPeripheral.shared
        backgroundPeriphTask?.cancel()
        backgroundPeriphTask = nil

        let startSemaphore = DispatchSemaphore(value: 0)

        let startTask = Task {
            defer { startSemaphore.signal() }
            do {
                let servicesWithChars = services.filter { !$0.characteristics.isEmpty }
                if !servicesWithChars.isEmpty {
                    result.infos.append("configuring \(servicesWithChars.count) service(s)...")
                    try await peripheral.configure(services: servicesWithChars)

                    for (uuid, data) in initialValues {
                        try? peripheral.updateValue(data, forCharacteristic: uuid)
                    }
                }

                result.infos.append("starting advertising as \"\(advName)\"...")
                try await peripheral.startAdvertising(name: advName, serviceUUIDs: serviceUUIDs)
                result.output.append(.peripheralSummary(PeriphSummaryResult(
                    name: advName, serviceUUIDs: serviceUUIDs.map(\.string), services: services
                )))
            } catch is CancellationError {
                // handled below
            } catch let error as BLEError {
                result.errors.append(error.localizedDescription)
                result.exitCode = error.exitCode
            } catch {
                result.errors.append("\(error)")
                result.exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(startTask, semaphore: startSemaphore, timeout: globals.timeout ?? 15.0) {
        case .interrupted:
            peripheral.stopAdvertising()
            result.exitCode = 130
            return result
        case .timedOut:
            result.errors.append("advertising failed to start (timed out)")
            result.exitCode = BlewExitCode.timeout.code
            return result
        case .completed:
            if result.exitCode != 0 { return result }
        }

        // Phase 2: event loop -- streaming, emits each event to caller
        if isInteractiveMode {
            backgroundPeriphTask = Task {
                let eventStream = peripheral.events()
                for await event in eventStream {
                    let ts = ISO8601DateFormatter.shared.string(from: Date())
                    emit(.peripheralEvent(PeriphEventRecord(timestamp: ts, event: event)))
                }
            }
            result.output.append(.message("Advertising in background. Use 'periph stop' to stop."))
            return result
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            let eventTask = Task {
                defer { semaphore.signal() }
                let eventStream = peripheral.events()
                for await event in eventStream {
                    let ts = ISO8601DateFormatter.shared.string(from: Date())
                    emit(.peripheralEvent(PeriphEventRecord(timestamp: ts, event: event)))
                    if Task.isCancelled { break }
                }
            }
            if case .interrupted = waitInterruptible(eventTask, semaphore: semaphore) {
                peripheral.stopAdvertising()
                result.output.append(.message("Stopped advertising."))
            }
            return result
        }
    }

    func runPeriphClone(_ args: [String], emit: @escaping @Sendable (CommandOutput) -> Void = { _ in }) -> CommandResult {
        var result = CommandResult()
        let cloneOpts = Self.targetingOptionsWithValue.union(["-o", "--save"])
        let savePath = parseStringOption(args, short: "-o", long: "--save", optionsWithValue: cloneOpts)

        let connectResult = ensureConnected(args: args, optionsWithValue: cloneOpts)
        guard connectResult.exitCode == 0 else { return connectResult }

        result.infos.append("snapshotting GATT tree...")

        var clonedServices: [ServiceDefinition] = []
        var clonedName: String = "blew-clone"
        var initialValues: [BLEUUID: Data] = [:]

        let snapSemaphore = DispatchSemaphore(value: 0)

        let snapTask = Task {
            defer { snapSemaphore.signal() }
            do {
                let tree = try await manager.discoverTree(includeDescriptors: false)

                let status = await manager.status()
                if let name = status.deviceName {
                    clonedName = name
                }

                for svc in tree {
                    let serviceUUID = try BLEUUID(parsing: svc.uuid)
                    var charDefs: [CharacteristicDefinition] = []
                    for char in svc.characteristics {
                        let charUUID = try BLEUUID(parsing: char.uuid)
                        let props = char.properties.compactMap { CharacteristicProperty(rawValue: mapPropertyName($0)) }

                        var valueStr: String? = nil
                        var valueFmt: String? = nil
                        if char.properties.contains("read") {
                            if let data = try? await manager.readCharacteristic(char.uuid) {
                                valueStr = data.map { String(format: "%02x", $0) }.joined()
                                valueFmt = "hex"
                                initialValues[charUUID] = data
                            }
                        }
                        charDefs.append(CharacteristicDefinition(
                            uuid: charUUID,
                            properties: props,
                            value: valueStr,
                            format: valueFmt
                        ))
                    }
                    clonedServices.append(ServiceDefinition(
                        uuid: serviceUUID,
                        primary: svc.isPrimary,
                        characteristics: charDefs
                    ))
                }
            } catch is CancellationError {
                // handled
            } catch let error as BLEUUID.ParseError {
                result.errors.append("the device reported an \(error.localizedDescription)")
                result.exitCode = BlewExitCode.operationFailed.code
            } catch let error as BLEError {
                result.errors.append(error.localizedDescription)
                result.exitCode = error.exitCode
            } catch {
                result.errors.append("\(error)")
                result.exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(snapTask, semaphore: snapSemaphore, timeout: globals.timeout ?? 15.0) {
        case .completed: break
        case .interrupted: result.exitCode = 130; return result
        case .timedOut:
            result.errors.append("GATT snapshot timed out")
            result.exitCode = BlewExitCode.timeout.code
            return result
        }
        if result.exitCode != 0 { return result }

        _ = runDisconnect([])

        if let path = savePath {
            let config = PeripheralConfig(name: clonedName, services: clonedServices)
            if let data = try? JSONEncoder().encode(config) {
                let pretty = (try? JSONSerialization.jsonObject(with: data)).flatMap {
                    try? JSONSerialization.data(withJSONObject: $0, options: .prettyPrinted)
                }
                let url = URL(fileURLWithPath: path)
                try? (pretty ?? data).write(to: url)
                result.infos.append("saved config to \(path)")
            }
        }

        let serviceUUIDs = clonedServices.map { $0.uuid }
        let peripheral = BLEPeripheral.shared
        backgroundPeriphTask?.cancel()
        backgroundPeriphTask = nil

        let startSemaphore = DispatchSemaphore(value: 0)

        let startTask = Task {
            defer { startSemaphore.signal() }
            do {
                result.infos.append("configuring \(clonedServices.count) cloned service(s)...")
                try await peripheral.configure(services: clonedServices)

                for (uuid, data) in initialValues {
                    try? peripheral.updateValue(data, forCharacteristic: uuid)
                }

                try await peripheral.startAdvertising(name: clonedName, serviceUUIDs: serviceUUIDs)
                result.output.append(.peripheralSummary(PeriphSummaryResult(
                    name: clonedName, serviceUUIDs: serviceUUIDs.map(\.string), services: clonedServices
                )))
            } catch is CancellationError {
                // handled below
            } catch let error as BLEError {
                result.errors.append(error.localizedDescription)
                result.exitCode = error.exitCode
            } catch {
                result.errors.append("\(error)")
                result.exitCode = BlewExitCode.operationFailed.code
            }
        }

        switch waitInterruptible(startTask, semaphore: startSemaphore, timeout: globals.timeout ?? 15.0) {
        case .interrupted:
            peripheral.stopAdvertising()
            result.exitCode = 130
            return result
        case .timedOut:
            result.errors.append("advertising failed to start (timed out)")
            result.exitCode = BlewExitCode.timeout.code
            return result
        case .completed:
            if result.exitCode != 0 { return result }
        }

        if isInteractiveMode {
            backgroundPeriphTask = Task {
                let eventStream = peripheral.events()
                for await event in eventStream {
                    let ts = ISO8601DateFormatter.shared.string(from: Date())
                    emit(.peripheralEvent(PeriphEventRecord(timestamp: ts, event: event)))
                }
            }
            result.output.append(.message("Advertising in background. Use 'periph stop' to stop."))
            return result
        } else {
            let semaphore = DispatchSemaphore(value: 0)
            let eventTask = Task {
                defer { semaphore.signal() }
                let eventStream = peripheral.events()
                for await event in eventStream {
                    let ts = ISO8601DateFormatter.shared.string(from: Date())
                    emit(.peripheralEvent(PeriphEventRecord(timestamp: ts, event: event)))
                    if Task.isCancelled { break }
                }
            }
            if case .interrupted = waitInterruptible(eventTask, semaphore: semaphore) {
                peripheral.stopAdvertising()
                result.output.append(.message("Stopped advertising."))
            }
            return result
        }
    }

    func runPeriphStop(_ args: [String]) -> CommandResult {
        var result = CommandResult()
        backgroundPeriphTask?.cancel()
        backgroundPeriphTask = nil
        BLEPeripheral.shared.stopAdvertising()
        result.output.append(.message("Stopped advertising."))
        return result
    }

    func runPeriphSet(_ args: [String]) -> CommandResult {
        var result = CommandResult()
        let positional = positionalArgs(args, optionsWithValue: ["-f", "--format"])
        guard positional.count >= 2 else {
            result.errors.append(positional.isEmpty
                ? "missing characteristic UUID and value"
                : "missing value")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }
        let charInput = positional[0]
        let valueStr = positional[1]
        let fmt = parseStringOption(args, short: "-f", long: "--format", optionsWithValue: ["-f", "--format"]) ?? "hex"

        let charUUID: BLEUUID
        do {
            charUUID = try resolvePeriphCharacteristic(charInput)
        } catch {
            result.errors.append(error.localizedDescription)
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        guard let data = DataFormatter.parse(valueStr, as: fmt) else {
            result.errors.append("invalid value '\(valueStr)' for format '\(fmt)'")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        do {
            try BLEPeripheral.shared.updateValue(data, forCharacteristic: charUUID)
            result.infos.append("set \(BLENames.displayUUID(charUUID.string, category: .characteristic)) = \(DataFormatter.format(data, as: fmt))")
        } catch let error as BLEError {
            result.errors.append(error.localizedDescription)
            result.exitCode = error.exitCode
        } catch {
            result.errors.append("\(error)")
            result.exitCode = BlewExitCode.operationFailed.code
        }
        return result
    }

    func runPeriphNotify(_ args: [String]) -> CommandResult {
        var result = CommandResult()
        let positional = positionalArgs(args, optionsWithValue: ["-f", "--format"])
        guard positional.count >= 2 else {
            result.errors.append(positional.isEmpty
                ? "missing characteristic UUID and value"
                : "missing value")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }
        let charInput = positional[0]
        let valueStr = positional[1]
        let fmt = parseStringOption(args, short: "-f", long: "--format", optionsWithValue: ["-f", "--format"]) ?? "hex"

        let charUUID: BLEUUID
        do {
            charUUID = try resolvePeriphCharacteristic(charInput)
        } catch {
            result.errors.append(error.localizedDescription)
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        guard let data = DataFormatter.parse(valueStr, as: fmt) else {
            result.errors.append("invalid value '\(valueStr)' for format '\(fmt)'")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        do {
            try BLEPeripheral.shared.updateValue(data, forCharacteristic: charUUID)
            result.infos.append("sent notification on \(BLENames.displayUUID(charUUID.string, category: .characteristic))")
        } catch let error as BLEError {
            result.errors.append(error.localizedDescription)
            result.exitCode = error.exitCode
        } catch {
            result.errors.append("\(error)")
            result.exitCode = BlewExitCode.operationFailed.code
        }
        return result
    }

    func runPeriphStatus(_ args: [String]) -> CommandResult {
        var result = CommandResult()
        let status = BLEPeripheral.shared.peripheralStatus()
        result.output.append(.peripheralStatus(status))
        return result
    }

    /// Write an event line that is safe to call while the terminal may be in raw mode
    /// (OPOST disabled by LineNoise). \r moves to column 0, \033[K erases any partial
    /// prompt or typed input on that line, and \r\n ends with a proper newline.

    private func resolvePeriphCharacteristic(_ input: String) throws -> BLEUUID {
        try Self.resolvePeriphCharacteristic(
            input, known: BLEPeripheral.shared.knownCharacteristicUUIDs())
    }

    struct AmbiguousCharacteristic: Error, LocalizedError {
        let input: String
        let matches: [String]

        var errorDescription: String? {
            "\(input.debugDescription) matches several characteristics: "
                + matches.joined(separator: ", ")
        }
    }

    /// The characteristic `input` names: `input` itself when it is a
    /// well-formed UUID (any spelling of a registered UUID finds it), else the
    /// one registered characteristic whose spelling starts with `input`, as
    /// REPL completion offers them. `known` is consulted only for a prefix.
    static func resolvePeriphCharacteristic(
        _ input: String, known: @autoclosure () -> [BLEUUID]
    ) throws -> BLEUUID {
        let parsed = Result { try BLEUUID(parsing: input) }
        if case .success(let uuid) = parsed { return uuid }
        let lower = input.lowercased()
        let matches = known().filter { $0.string.lowercased().hasPrefix(lower) }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            return try parsed.get()
        default:
            throw AmbiguousCharacteristic(input: input, matches: matches.map(\.string).sorted())
        }
    }

    private func mapPropertyName(_ prop: String) -> String {
        switch prop {
        case "writeNoResp": return "writeWithoutResponse"
        default: return prop
        }
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

extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
