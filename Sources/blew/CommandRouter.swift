import Foundation
import BLEManager

final class CommandRouter {
    let globals: GlobalOptions
    let manager: BLECentral
    let output: OutputFormatter
    let renderer: OutputRenderer
    let isInteractiveMode: Bool
    /// The devices the last scan matched, in the order first seen.
    var lastScanResults: [DiscoveredDevice] = []
    /// The scan record of the device `connect(to:)` last connected, so a
    /// later scan that no longer sees it does not lose what it advertised.
    private var connectedAdvertisement: DiscoveredDevice?
    /// The caller's request to stop the command that is running, besides
    /// SIGINT; set only inside `run(stoppingOn:_:)`.
    private var stopRequest: StopRequest?
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
        let commands: [String]
        do {
            commands = try splitScript(script)
        } catch {
            var result = CommandResult()
            result.fail(error)
            renderer.renderResult(result)
            return result.exitCode
        }

        if dryRun {
            for (i, cmd) in commands.enumerated() {
                print("[\(i + 1)] \(TerminalText.escape(cmd))")
            }
            return 0
        }

        var firstError: Int32 = 0
        for cmd in commands {
            let result = dispatch(cmd)
            if result.exitCode != 0 {
                if firstError == 0 { firstError = result.exitCode }
                // Ctrl-C stops the script, also with --keep-going.
                if !keepGoing || result.exitCode == BlewExitCode.interrupted.code {
                    return result.exitCode
                }
            }
        }
        return firstError
    }

    /// Parse and dispatch a single command line. Returns CommandResult.
    func dispatch(_ line: String) -> CommandResult {
        let tokens: [String]
        do {
            tokens = try tokenize(line)
        } catch {
            var result = CommandResult()
            result.fail(error)
            renderer.renderResult(result)
            return result
        }
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

    /// One character of command text as the quoting rule reads it.
    enum QuotedCharacter {
        /// A `"` or `'` that opens or closes a quoted string.
        case quote(Character)
        /// Any other character; `quoted` when it is inside a quoted string.
        case text(Character, quoted: Bool)
    }

    /// The one quoting rule of scripts and command lines: `"` or `'` opens a
    /// quoted string that runs to the next of the same character, without
    /// escapes. Throws for a quote that is never closed, so it cannot
    /// swallow the rest of a script.
    static func readQuoting(_ text: String) throws -> [QuotedCharacter] {
        var characters: [QuotedCharacter] = []
        var open: Character?
        for ch in text {
            if let quote = open {
                if ch == quote {
                    open = nil
                    characters.append(.quote(ch))
                } else {
                    characters.append(.text(ch, quoted: true))
                }
            } else if ch == "\"" || ch == "'" {
                open = ch
                characters.append(.quote(ch))
            } else {
                characters.append(.text(ch, quoted: false))
            }
        }
        if let quote = open {
            throw InvalidArgument("unclosed \(quote) quote")
        }
        return characters
    }

    /// The commands of a script: its text split at each `;` outside quotes,
    /// trimmed, without empty ones. Quotes stay in the command for
    /// `tokenize`.
    func splitScript(_ script: String) throws -> [String] {
        var commands: [String] = []
        var current = ""
        for character in try Self.readQuoting(script) {
            switch character {
            case .text(";", quoted: false):
                commands.append(current)
                current = ""
            case .text(let ch, _), .quote(let ch):
                current.append(ch)
            }
        }
        commands.append(current)
        return commands.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The tokens of a command line: split at spaces and tabs outside
    /// quotes, with the quotes removed.
    func tokenize(_ line: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in try Self.readQuoting(line) {
            switch character {
            case .quote:
                break
            case .text(let ch, quoted: false) where ch == " " || ch == "\t":
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            case .text(let ch, _):
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    // MARK: - Command runners (called from REPL/exec)

    /// Options of `scan` that take a value.
    static let scanOptionsWithValue: Set<String> = targetingOptionsWithValue.union(["-t", "--timeout"])

    func runScan(_ args: [String]) -> CommandResult {
        let args = expandArgs(args, optionsWithValue: Self.scanOptionsWithValue)
        let target: DeviceTarget
        let duration: TimeInterval?
        do {
            target = try DeviceTarget.parse(args, optionsWithValue: Self.scanOptionsWithValue)
            duration = try scanDuration(args)
        } catch {
            return Self.invalidArguments("\(error)")
        }

        if hasFlag(args, short: "-w", long: "--watch", optionsWithValue: Self.scanOptionsWithValue) {
            guard target.pick == nil else {
                return Self.invalidArguments("--pick chooses one device; it does not apply to --watch")
            }
            return runScanWatch(filter: target.filter, timeout: duration)
        }

        var (devices, result) = scanForDevices(timeout: duration ?? 5.0, filter: target.filter)
        guard result.exitCode == 0 else { return result }
        if let pick = target.pick {
            guard let device = choose(pick, from: devices, into: &result) else { return result }
            devices = [device]
        }
        result.output.append(.devices(Self.deviceRows(devices.byRSSI)))
        return result
    }

    /// The scan duration: `scan -t` in `args`, else the global `-t`; nil
    /// when neither is given. Throws when the value is not a duration
    /// `isValidDuration` accepts, since a scan stop is scheduled with a
    /// nanosecond sleep.
    private func scanDuration(_ args: [String]) throws -> TimeInterval? {
        let local = try optionValue(args, short: "-t", long: "--timeout", optionsWithValue: Self.scanOptionsWithValue)
        guard let text = local ?? globals.timeout.map({ "\($0)" }) else { return nil }
        guard let seconds = Double(text), Self.isValidDuration(seconds) else {
            throw InvalidArgument("invalid timeout '\(text)' (use 0 to \(Int(Self.maxDuration)) seconds)")
        }
        return seconds
    }

    /// The scan duration auto-connect uses: the global `-t`, else 5 seconds.
    private func autoConnectScanDuration() throws -> TimeInterval {
        try scanDuration([]) ?? 5.0
    }

    static func invalidArguments(_ message: String) -> CommandResult {
        var result = CommandResult()
        result.errors.append(message)
        result.exitCode = BlewExitCode.invalidArguments.code
        return result
    }

    private static func deviceRows(_ devices: [DiscoveredDevice]) -> [DeviceRow] {
        devices.map { d in
            DeviceRow(id: d.identifier, name: d.name, rssi: d.rssi,
                      serviceUUIDs: d.serviceUUIDs,
                      serviceDisplayNames: d.serviceUUIDs.map { BLENames.displayUUID($0, category: .service) })
        }
    }

    /// Scan for `timeout` seconds (a duration `isValidDuration` accepts) and
    /// return the devices that match `filter`, in the order first seen; they
    /// also become `lastScanResults`. A failed or interrupted scan, or one
    /// that finds no matching device, gives a nonzero exit code.
    private func scanForDevices(timeout: TimeInterval, filter: DeviceFilter) -> (devices: [DiscoveredDevice], result: CommandResult) {
        let interactive = isatty(fileno(stderr)) != 0
        let spinner: ScanSpinner? = interactive ? ScanSpinner(timeout: timeout) : nil
        if !interactive {
            renderer.renderInfo("scanning for \(timeout)s...")
        }
        spinner?.start()

        var results = ScanResults()
        var result = CommandResult()

        let operation: () async -> Void = { [self] in
            do {
                let stream = try await manager.scan(timeout: timeout)
                for await device in stream {
                    results.add(device)
                    spinner?.deviceCount = results.matching(filter).count
                }
            } catch is CancellationError {
                // interrupted; reported below
            } catch {
                result.fail(error)
            }
        }

        let outcome = waitInterruptible(operation)
        spinner?.stop()

        if case .interrupted = outcome { result.exitCode = BlewExitCode.interrupted.code; return ([], result) }
        if result.exitCode != 0 { return ([], result) }

        let devices = results.matching(filter)
        lastScanResults = devices
        if devices.isEmpty {
            result.errors.append("no devices found")
            result.exitCode = BlewExitCode.notFound.code
        }
        return (devices, result)
    }

    /// The device `pick` chooses from `candidates` (in the order first seen),
    /// or nil with the error and exit code recorded in `result`.
    private func choose(_ pick: PickStrategy, from candidates: [DiscoveredDevice],
                        into result: inout CommandResult) -> DiscoveredDevice? {
        switch pick.choose(from: candidates) {
        case .picked(let device):
            return device
        case .noDevices:
            result.errors.append("no devices found")
        case .several(let devices):
            result.errors.append("--pick only: \(devices.count) devices found, expected exactly one")
            for d in devices {
                result.errors.append("  " + (d.name.map { "\($0) (\(d.identifier))" } ?? d.identifier))
            }
        }
        result.exitCode = BlewExitCode.notFound.code
        return nil
    }

    private func runScanWatch(filter: DeviceFilter, timeout: TimeInterval?) -> CommandResult {
        if output.format == .kv {
            return runScanWatchKV(filter: filter, timeout: timeout)
        }

        guard isatty(fileno(stdout)) != 0 else {
            return Self.invalidArguments("scan --watch in text mode requires an interactive terminal; use -o kv for piped output")
        }

        let display = ScanWatchDisplay(formatter: output)
        display.start()

        var scanFailure: Error?
        var results = ScanResults()

        let operation: () async -> Void = { [self] in
            do {
                let stream = try await manager.scan(timeout: timeout, allowDuplicates: true)
                for await device in stream {
                    results.add(device)
                    display.update(devices: results.matching(filter).byRSSI)
                }
            } catch is CancellationError {
                // normal exit path
            } catch {
                scanFailure = error
            }
        }

        let outcome = waitInterruptible(operation)
        display.stop()

        var result = CommandResult()
        let devices = results.matching(filter)
        lastScanResults = devices

        if case .interrupted = outcome {
            if !devices.isEmpty {
                result.output.append(.devices(Self.deviceRows(devices.byRSSI)))
            }
            result.exitCode = BlewExitCode.interrupted.code
            return result
        }

        if let scanFailure { result.fail(scanFailure); return result }

        if devices.isEmpty {
            result.errors.append("no devices found")
            result.exitCode = BlewExitCode.notFound.code
            return result
        }
        result.output.append(.devices(Self.deviceRows(devices.byRSSI)))
        return result
    }

    private func runScanWatchKV(filter: DeviceFilter, timeout: TimeInterval?) -> CommandResult {
        var scanFailure: Error?
        var results = ScanResults()

        let operation: () async -> Void = { [self] in
            do {
                let stream = try await manager.scan(timeout: timeout, allowDuplicates: true)
                for await device in stream {
                    let merged = results.add(device)
                    guard filter.matches(merged) else { continue }
                    renderer.render(.devices(Self.deviceRows([merged])))
                }
            } catch is CancellationError {
                // normal exit
            } catch {
                scanFailure = error
            }
        }

        var result = CommandResult()
        let outcome = waitInterruptible(operation)
        lastScanResults = results.matching(filter)
        if case .interrupted = outcome {
            result.exitCode = BlewExitCode.interrupted.code
            return result
        }
        if let scanFailure { result.fail(scanFailure); return result }
        return result
    }

    /// `connect <device>` (or `-i`) connects to that device; `connect` with
    /// selectors scans for one. Either way the device is connected afresh,
    /// replacing the connected one once it is found; `connect` with no
    /// device named keeps a connected device.
    func runConnect(_ args: [String]) -> CommandResult {
        let options = Self.targetingOptionsWithValue
        if let device = positionalArgs(args, optionsWithValue: options).first {
            return ensureConnected(args: ["-i", device], optionsWithValue: options, reconnect: true)
        }
        return ensureConnected(args: args, optionsWithValue: options, reconnect: true)
    }

    /// Connect to the device with identifier `targetId`, and remember its
    /// record from the last scan as the connected device's advertisement.
    private func connect(to targetId: String) -> CommandResult {
        let connectTimeout = globals.timeout ?? 10.0
        var result = CommandResult()
        let record = lastScanResults.first { $0.identifier.caseInsensitiveCompare(targetId) == .orderedSame }

        let label = record?.name.map { "\($0) (\(targetId))" } ?? targetId
        result.infos.append("connecting to \(label)...")

        let operation: () async -> Void = { [self] in
            do {
                try await manager.connect(deviceId: targetId, timeout: connectTimeout)
                result.infos.append("connected to \(targetId)")
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch {
                result.fail(error)
            }
        }

        switch waitInterruptible(operation, timeout: connectTimeout) {
        case .completed: if result.exitCode == 0 { connectedAdvertisement = record }
        case .interrupted: result.exitCode = BlewExitCode.interrupted.code
        case .timedOut:
            result.errors.append("connection timed out")
            result.exitCode = BlewExitCode.timeout.code
        }
        return result
    }

    private static func ambiguousDevice(_ input: String, _ matches: [DiscoveredDevice]) -> CommandResult {
        var result = CommandResult()
        result.errors.append("ambiguous device '\(input)' -- matches:")
        for d in matches {
            let label = d.name.map { "\($0) (\(d.identifier))" } ?? d.identifier
            result.errors.append("  \(label)")
        }
        result.exitCode = BlewExitCode.invalidArguments.code
        return result
    }

    func runDisconnect(_ args: [String]) -> CommandResult {
        var result = CommandResult()

        let operation: () async -> Void = { [self] in
            do {
                try await manager.disconnect()
                result.infos.append("disconnected")
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch {
                result.fail(error)
            }
        }

        switch waitInterruptible(operation, timeout: globals.timeout ?? 5.0) {
        case .completed: break
        case .interrupted: result.exitCode = BlewExitCode.interrupted.code
        case .timedOut:
            result.errors.append("disconnect timed out")
            result.exitCode = BlewExitCode.timeout.code
        }
        return result
    }

    func runStatus(_ args: [String]) -> CommandResult {
        var result = CommandResult()

        let operation: () async -> Void = { [self] in
            let status = await manager.status()
            result.output.append(.connectionStatus(status))
        }

        if case .interrupted = waitInterruptible(operation) {
            result.exitCode = BlewExitCode.interrupted.code
        }
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

        let operation: () async -> Void = {
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

        if case .interrupted = waitInterruptible(operation) {
            result.exitCode = BlewExitCode.interrupted.code
        }
        return result
    }

    /// The `gatt tree`/`gatt chars` flags at option positions of `args`:
    /// `-d`/`--descriptors` and `-r`/`--read`. An option value or a token
    /// after `--` that spells a flag is not one.
    func gattFlags(_ args: [String]) -> (descriptors: Bool, values: Bool) {
        let options = Self.targetingOptionsWithValue
        return (hasFlag(args, short: "-d", long: "--descriptors", optionsWithValue: options),
                hasFlag(args, short: "-r", long: "--read", optionsWithValue: options))
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

        // Arguments are checked before auto-connect, which may replace the connected device.
        guard ["svcs", "tree", "chars", "desc"].contains(sub) else {
            var result = Self.invalidArguments("unknown gatt subcommand '\(sub)'")
            result.output.append(.message("Usage: gatt <svcs|tree|chars|desc|info>"))
            return result
        }
        if sub == "desc", positionalArgs(args, optionsWithValue: targetingOpts).count < 2 {
            return Self.invalidArguments("missing characteristic UUID")
        }

        let connectResult = ensureConnected(args: args, optionsWithValue: targetingOpts)
        guard connectResult.exitCode == 0 else { return connectResult }

        var result = CommandResult()

        let operation: () async -> Void = { [self] in
            do {
                switch sub {
                case "svcs":
                    let services = try await manager.discoverServices()
                    let rows = services.map { svc in
                        ServiceRow(uuid: svc.uuid, name: BLENames.name(for: svc.uuid, category: .service), isPrimary: svc.isPrimary)
                    }
                    result.output.append(.services(rows))

                case "tree":
                    let flags = gattFlags(args)
                    let includeDescriptors = flags.descriptors
                    let includeValues = flags.values
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
                                        ?? DataFormatter.format(data, as: .hex)
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
                    let includeValues = gattFlags(args).values
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
                                    ?? DataFormatter.format(data, as: .hex)
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
            } catch {
                result.fail(error)
            }
        }

        switch waitInterruptible(operation, timeout: globals.timeout ?? 10.0) {
        case .completed: break
        case .interrupted: result.exitCode = BlewExitCode.interrupted.code
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
        // Arguments are checked before auto-connect, which may replace the connected device.
        guard let charInput = positionalArgs(args, optionsWithValue: readOpts).first else {
            return Self.invalidArguments("missing characteristic UUID")
        }
        let fmt: ValueFormat
        do {
            fmt = try valueFormat(args, optionsWithValue: readOpts)
        } catch {
            return Self.invalidArguments("\(error)")
        }
        let connectResult = ensureConnected(args: args, optionsWithValue: readOpts)
        guard connectResult.exitCode == 0 else { return connectResult }

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

        let operation: () async -> Void = { [self] in
            do {
                let data = try await manager.readCharacteristic(charUUID)
                let formatted = DataFormatter.format(data, as: fmt)
                let name = BLENames.name(for: charUUID, category: .characteristic)
                result.output.append(.readValue(ReadResult(char: charUUID, name: name, value: formatted, format: fmt)))
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch {
                result.fail(error)
            }
        }

        switch waitInterruptible(operation, timeout: globals.timeout ?? 5.0) {
        case .completed: break
        case .interrupted: result.exitCode = BlewExitCode.interrupted.code
        case .timedOut:
            result.errors.append("read timed out")
            result.exitCode = BlewExitCode.timeout.code
        }
        return result
    }

    func runWrite(_ args: [String]) -> CommandResult {
        let writeOpts = Self.targetingOptionsWithValue.union(["-f", "--format"])
        let args = expandArgs(args, optionsWithValue: writeOpts)
        // Arguments are checked before auto-connect, which may replace the connected device.
        let positional = positionalArgs(args, optionsWithValue: writeOpts)
        guard positional.count >= 2 else {
            return Self.invalidArguments(positional.isEmpty ? "missing characteristic UUID and data" : "missing data to write")
        }
        let charInput = positional[0]
        let dataStr = positional[1]
        let fmt: ValueFormat
        do {
            fmt = try valueFormat(args, optionsWithValue: writeOpts)
        } catch {
            return Self.invalidArguments("\(error)")
        }
        guard let data = DataFormatter.parse(dataStr, as: fmt) else {
            return Self.invalidArguments("invalid data '\(dataStr)' for format '\(fmt.rawValue)'")
        }
        let connectResult = ensureConnected(args: args, optionsWithValue: writeOpts)
        guard connectResult.exitCode == 0 else { return connectResult }

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
        let withResponse = hasFlag(args, short: "-r", long: "--with-response", optionsWithValue: writeOpts)
        let withoutResponse = hasFlag(args, short: "-w", long: "--without-response", optionsWithValue: writeOpts)

        let writeType: WriteType
        if withResponse {
            writeType = .withResponse
        } else if withoutResponse {
            writeType = .withoutResponse
        } else {
            writeType = .auto
        }

        let operation: () async -> Void = { [self] in
            do {
                try await manager.writeCharacteristic(charUUID, data: data, type: writeType)
                result.infos.append("written to \(BLENames.displayUUID(charUUID, category: .characteristic))")
                result.output.append(.writeSuccess(char: charUUID, name: BLENames.name(for: charUUID, category: .characteristic)))
            } catch is CancellationError {
                // handled by waitInterruptible
            } catch {
                result.fail(error)
            }
        }

        switch waitInterruptible(operation, timeout: globals.timeout ?? 5.0) {
        case .completed: break
        case .interrupted: result.exitCode = BlewExitCode.interrupted.code
        case .timedOut:
            result.errors.append("write timed out")
            result.exitCode = BlewExitCode.timeout.code
        }
        return result
    }

    /// `foregroundOnly` (the MCP server) leaves `-b` and `--bg` without
    /// meaning, so no argument text can start a background subscription
    /// that outlives the call.
    func runSub(_ args: [String], foregroundOnly: Bool = false,
                emit: @escaping @Sendable (CommandOutput) -> Void = { _ in }) -> CommandResult {
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
        let durationText: String?
        do {
            durationText = try optionValue(args, short: "-d", long: "--duration", optionsWithValue: subOpts)
        } catch {
            return Self.invalidArguments("\(error)")
        }
        let duration = durationText.flatMap(Double.init)
        if let durationText, !(duration.map(Self.isValidDuration) ?? false) {
            result.errors.append("invalid duration '\(durationText)' (use 0 to \(Int(Self.maxDuration)) seconds)")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        let backgroundFlags: Set<String> = foregroundOnly ? [] : ["--bg", "-b"]
        let background = args.contains { backgroundFlags.contains($0) }
        let positionals = positionalArgs(args.filter { !backgroundFlags.contains($0) }, optionsWithValue: subOpts)
        // Arguments are checked before auto-connect, which may replace the connected device.
        guard let charInput = positionals.first else {
            return Self.invalidArguments("missing characteristic UUID")
        }
        let fmt: ValueFormat
        let maxCount: Int?
        do {
            fmt = try valueFormat(args, optionsWithValue: subOpts)
            maxCount = try notificationCount(args, optionsWithValue: subOpts)
        } catch {
            return Self.invalidArguments("\(error)")
        }
        let connectResult = ensureConnected(args: args, optionsWithValue: subOpts)
        guard connectResult.exitCode == 0 else { return connectResult }
        let charUUID: String
        switch resolveCharacteristic(charInput) {
        case .resolved(let uuid): charUUID = uuid
        case .ambiguous(let uuids):
            result.errors.append("ambiguous characteristic '\(charInput)' -- matches: \(uuids.joined(separator: ", "))")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        case .notFound: charUUID = charInput
        }
        // Enabling notifications waits for the device to confirm; that wait
        // has the operation timeout, like a read.
        let setupTimeout = globals.timeout ?? 5.0
        let manager = self.manager

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
                    let stream = try await Self.withDeadline(setupTimeout) {
                        try await manager.subscribe(characteristicUUID: charUUID)
                    }
                    try await Self.forEachNotification(stream, maxCount: maxCount, duration: duration) { data in
                        capturedRenderer.renderLive("[\(charUUID)] \(DataFormatter.format(data, as: fmt))")
                    }
                } catch is CancellationError {
                    // stopped
                } catch {
                    capturedRenderer.renderLive("sub error [\(charUUID)]: \(error.localizedDescription)")
                }
                backgroundSubTasks.removeValue(forKey: charUUID)
            }
            let displayUUID = BLENames.displayUUID(charUUID, category: .characteristic)
            result.output.append(.message("Subscribing to \(displayUUID) in background. Use 'sub stop \(charUUID)' to stop."))
            return result
        }

        // Foreground subscription: streaming command, emits each notification to caller

        let operation: () async -> Void = {
            do {
                let stream = try await Self.withDeadline(setupTimeout) {
                    try await manager.subscribe(characteristicUUID: charUUID)
                }
                let charName = BLENames.name(for: charUUID, category: .characteristic)
                try await Self.forEachNotification(stream, maxCount: maxCount, duration: duration) { data in
                    let ts = ISO8601DateFormatter.shared.string(from: Date())
                    emit(.notification(NotificationValue(timestamp: ts, char: charUUID, name: charName,
                                                         value: DataFormatter.format(data, as: fmt))))
                }
            } catch is CancellationError {
                // interrupted
            } catch {
                result.fail(error)
            }
        }

        if case .interrupted = waitInterruptible(operation) {
            result.exitCode = BlewExitCode.interrupted.code
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
    /// the stream ends. Ending the iteration ends the subscription. Throws
    /// the error the stream ends with (the connection ended).
    static func forEachNotification(_ stream: AsyncThrowingStream<Data, Error>, maxCount: Int?, duration: TimeInterval?,
                                    _ handle: @escaping @Sendable (Data) -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var count = 0
                for try await data in stream {
                    handle(data)
                    count += 1
                    if let maxCount, count >= maxCount { return }
                }
            }
            if let duration {
                group.addTask { try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Run `operation`, throwing `BLEError.timeout` and cancelling it when
    /// it has not finished after `seconds`.
    static func withDeadline<T: Sendable>(_ seconds: TimeInterval,
                                          _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw BLEError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    // MARK: - Interrupt-aware wait

    /// Run `body` as one command with `request` attached: while it runs,
    /// every `waitInterruptible` stops when the request is set, as it does
    /// on SIGINT. The whole of `body` is one signal span, like a REPL
    /// command, so a SIGINT between two waits stops the command at its next
    /// wait instead of ending the process. The MCP server runs each tool
    /// call this way.
    func run<T>(stoppingOn request: StopRequest, _ body: () -> T) -> T {
        let outer = stopRequest
        stopRequest = request
        let signals = ProcessSignals.shared
        signals.commandStarted()
        defer {
            signals.commandFinished()
            stopRequest = outer
        }
        return body()
    }

    enum CommandOutcome { case completed, interrupted, timedOut }

    /// Run `operation` in a Task and block the calling thread until it
    /// finishes, polling every 50 ms. A stop (a Ctrl-C interrupt, or the
    /// attached `StopRequest` set):
    ///   - requested before `waitInterruptible` is called keeps the
    ///     operation from starting, and gives `.interrupted`;
    ///   - seen by the poll while the operation runs cancels the task, waits
    ///     for it, and gives `.interrupted`;
    ///   - arriving as the operation finishes, before the poll sees it,
    ///     leaves the result `.completed`: the operation did happen. The stop
    ///     stays set until the command's outermost span closes (see
    ///     `ProcessSignals`), so the next wait of the same command does not
    ///     start its operation.
    /// If a timeout is provided and the deadline passes before the
    /// operation finishes, the task is cancelled and we return `.timedOut`.
    func waitInterruptible(
        _ operation: @escaping () async -> Void,
        timeout: TimeInterval? = nil
    ) -> CommandOutcome {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        let signals = ProcessSignals.shared
        signals.commandStarted()
        defer { signals.commandFinished() }
        let stopRequested = { signals.interruptRequested || self.stopRequest?.reason != nil }
        if stopRequested() { return .interrupted }
        let finished = DispatchSemaphore(value: 0)
        let task = Task {
            defer { finished.signal() }
            await operation()
        }
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            if stopRequested() {
                task.cancel()
                _ = finished.wait(timeout: .now() + 2.0)
                return .interrupted
            }
            if let dl = deadline, Date() > dl {
                task.cancel()
                _ = finished.wait(timeout: .now() + 2.0)
                return .timedOut
            }
        }
        // The operation finished: report what it did, even if a stop arrived
        // while it ran. The stop still keeps the next operation from starting.
        return .completed
    }

    // MARK: - Auto-connect

    /// Options of the device-targeting group that take a value.
    static let targetingOptionsWithValue: Set<String> = [
        "-i", "--id", "-n", "--name", "-S", "--service", "-m", "--manufacturer", "-R", "--rssi-min", "-p", "--pick",
    ]

    /// Make sure the device the targeting options in `args` name is
    /// connected before an operation. `AutoConnectPlan` decides:
    ///   - a connected device is used when it is the target, or when the
    ///     options name no device;
    ///   - otherwise `-i` connects directly, and the selectors (`-n`, `-S`,
    ///     `-m`, `-R`) scan and connect to the device `-p` picks;
    ///   - with nothing connected and nothing named, `defaultFilter` is
    ///     scanned for when it is set, and otherwise it is an error.
    /// A connected device that is not the target is disconnected only once
    /// the new device is known: after `-i` resolved to an identifier, or
    /// after the scan picked one. A failed lookup leaves it connected.
    /// With `reconnect`, a target that names a device is connected afresh
    /// even when it is the connected one (`connect`).
    /// `optionsWithValue` lists the calling command's options that take a
    /// value, so their values are never read as targeting options.
    func ensureConnected(args: [String], optionsWithValue: Set<String>,
                         defaultFilter: DeviceFilter = DeviceFilter(), reconnect: Bool = false) -> CommandResult {
        var target: DeviceTarget
        do {
            target = try DeviceTarget.parse(args, optionsWithValue: optionsWithValue)
        } catch {
            return Self.invalidArguments("\(error)")
        }
        // `-i` also takes a name or an identifier fragment from the last
        // scan; compare the full identifier it stands for.
        if let input = target.filter.id {
            switch resolveDevice(input) {
            case .resolved(let device): target.filter.id = device.identifier
            case .ambiguous(let matches): return Self.ambiguousDevice(input, matches)
            case .notFound: break
            }
        }

        let connected = connectedDevice()
        let deviceId: String
        switch AutoConnectPlan.make(target: target, defaultFilter: defaultFilter, connected: connected,
                                    reconnect: reconnect) {
        case .useConnected:
            return CommandResult()
        case .noTarget:
            return Self.invalidArguments("not connected -- specify a device with --id or --name")
        case .connect(let id):
            guard UUID(uuidString: id) != nil else {
                var result = CommandResult()
                result.errors.append("device '\(id)' not found: it is not an identifier, and no device of the last scan matches it")
                result.exitCode = BlewExitCode.notFound.code
                return result
            }
            deviceId = id
        case .scan(let filter, let pick):
            let duration: TimeInterval
            do {
                duration = try autoConnectScanDuration()
            } catch {
                return Self.invalidArguments("\(error)")
            }
            var (devices, result) = scanForDevices(timeout: duration, filter: filter)
            guard result.exitCode == 0 else { return result }
            guard let device = choose(pick, from: devices, into: &result) else { return result }
            deviceId = device.identifier
        }

        // BLECentral.connect disconnects the connected device first.
        if let connected, connected.id.caseInsensitiveCompare(deviceId) != .orderedSame {
            renderer.renderInfo("replacing the connected device \(connected.id)")
        }
        return connect(to: deviceId)
    }

    /// The connected device with its advertisement: the record of the scan
    /// it was connected from, or else of the last scan. Nil when nothing is
    /// connected.
    private func connectedDevice() -> ConnectedDevice? {
        var status: ConnectionStatus?
        let statusSem = DispatchSemaphore(value: 0)
        Task {
            status = await manager.status()
            statusSem.signal()
        }
        statusSem.wait()
        guard let status, status.isConnected, let id = status.deviceId else { return nil }
        func isConnected(_ device: DiscoveredDevice) -> Bool {
            device.identifier.caseInsensitiveCompare(id) == .orderedSame
        }
        let record = connectedAdvertisement.flatMap { isConnected($0) ? $0 : nil }
            ?? lastScanResults.first(where: isConnected)
        return ConnectedDevice(id: id, advertisement: record)
    }

    // MARK: - Argument parsing helpers

    /// Expand combined single-dash short flags into individual flags.
    /// For example, `["-dr"]` becomes `["-d", "-r"]`. Long flags (`--foo`)
    /// and single-char flags (`-d`) are passed through unchanged.
    /// Tokens after `--`, and numbers (`-12`), are values and stay as they are.
    func expandArgs(_ args: [String], optionsWithValue: Set<String> = []) -> [String] {
        var result: [String] = []
        var skipNext = false
        for (index, arg) in args.enumerated() {
            if skipNext {
                result.append(arg)
                skipNext = false
                continue
            }
            if arg == Self.endOfOptions {
                result += args[index...]
                break
            }
            if Self.isOption(arg) && !arg.hasPrefix("--") && arg.count > 2 {
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

    /// `--` ends the options: every token after it is positional, whatever
    /// it looks like (`write fff1 -- -x`).
    static let endOfOptions = "--"

    /// Whether `arg`, at an option position, is an option: it starts with
    /// `-` and is not a number, so `write -f float32le fff1 -1.5` writes
    /// -1.5. No option of blew is a number.
    static func isOption(_ arg: String) -> Bool {
        arg.hasPrefix("-") && Double(arg) == nil
    }

    /// Collect non-flag positional tokens from args. Options listed in
    /// `optionsWithValue` consume their following token and are skipped;
    /// every token after `--` is positional.
    func positionalArgs(_ args: [String], optionsWithValue: Set<String>) -> [String] {
        var result: [String] = []
        var tokens = args[...]
        while let arg = tokens.popFirst() {
            if arg == Self.endOfOptions {
                result += tokens
                break
            }
            if Self.isOption(arg) {
                if optionsWithValue.contains(arg) { _ = tokens.popFirst() }
            } else {
                result.append(arg)
            }
        }
        return result
    }

    /// The options at option positions of `args`, in order, each with its
    /// value. An option in `optionsWithValue` takes the next token whatever it
    /// looks like (nil when there is none), `--long=value` carries its own,
    /// and any other option is a flag. Positional tokens are skipped, and the
    /// walk ends at `--`. Every option lookup goes through this one walk, so
    /// a value is never read as an option.
    static func scanOptions(_ args: [String], optionsWithValue: Set<String>) -> [(name: String, value: String?)] {
        var options: [(name: String, value: String?)] = []
        var tokens = args[...]
        while let arg = tokens.popFirst() {
            if arg == endOfOptions { break }
            guard isOption(arg) else { continue }
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

    /// The value of the option `short`/`long`, which takes one value, in
    /// `args`; nil when it is absent. Throws when it ends `args` without its
    /// value or is given more than once, so a missing value never reads as
    /// a missing option.
    func optionValue(_ args: [String], short: String, long: String, optionsWithValue: Set<String>) throws -> String? {
        let values = try optionValues(args, short: short, long: long, optionsWithValue: optionsWithValue)
        guard values.count <= 1 else { throw InvalidArgument("\(long) is given more than once") }
        return values.first
    }

    /// Every value of the repeatable option `short`/`long` in `args`, in
    /// order. Throws when it ends `args` without its value, so a missing
    /// value never reads as a missing option.
    func optionValues(_ args: [String], short: String, long: String, optionsWithValue: Set<String>) throws -> [String] {
        try Self.scanOptions(args, optionsWithValue: optionsWithValue.union([short, long]))
            .filter { $0.name == short || $0.name == long }
            .map { option in
                guard let value = option.value else { throw InvalidArgument("\(option.name) needs a value") }
                return value
            }
    }

    /// The `-f`/`--format` of `args`, hex when it is absent. Throws for a
    /// name that is not a `ValueFormat`.
    func valueFormat(_ args: [String], optionsWithValue: Set<String>) throws -> ValueFormat {
        try ValueFormat(parsing: optionValue(args, short: "-f", long: "--format",
                                             optionsWithValue: optionsWithValue) ?? "hex")
    }

    /// The `sub -c`/`--count` of `args`, nil (no limit) when it is absent.
    /// Throws for anything but a whole number of at least 1.
    func notificationCount(_ args: [String], optionsWithValue: Set<String>) throws -> Int? {
        guard let text = try optionValue(args, short: "-c", long: "--count", optionsWithValue: optionsWithValue) else {
            return nil
        }
        guard let count = Int(text), count >= 1 else {
            throw InvalidArgument("invalid count '\(text)' (use a whole number of at least 1)")
        }
        return count
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
        let configPath: String?
        let nameArg: String?
        do {
            configPath = try optionValue(args, short: "-c", long: "--config", optionsWithValue: advOpts)
            nameArg = try optionValue(args, short: "-n", long: "--name", optionsWithValue: advOpts)
        } catch {
            return Self.invalidArguments("\(error)")
        }
        let serviceArgs = parseAllStringOptions(args, short: "-S", long: "--service", optionsWithValue: advOpts)

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

        let startOperation: () async -> Void = {
            do {
                let servicesWithChars = services.filter { !$0.characteristics.isEmpty }
                if !servicesWithChars.isEmpty {
                    result.infos.append("configuring \(servicesWithChars.count) service(s)...")
                    try await peripheral.configure(services: servicesWithChars)

                    for (uuid, data) in initialValues {
                        _ = try? peripheral.updateValue(data, forCharacteristic: uuid)
                    }
                }

                result.infos.append("starting advertising as \"\(advName)\"...")
                try await peripheral.startAdvertising(name: advName, serviceUUIDs: serviceUUIDs)
                result.output.append(.peripheralSummary(PeriphSummaryResult(
                    name: advName, serviceUUIDs: serviceUUIDs.map(\.string), services: services
                )))
            } catch is CancellationError {
                // handled below
            } catch {
                result.fail(error)
            }
        }

        switch waitInterruptible(startOperation, timeout: globals.timeout ?? 15.0) {
        case .interrupted:
            peripheral.stopAdvertising()
            result.exitCode = BlewExitCode.interrupted.code
            return result
        case .timedOut:
            peripheral.stopAdvertising()
            result.errors.append("advertising failed to start (timed out)")
            result.exitCode = BlewExitCode.timeout.code
            return result
        case .completed:
            if result.exitCode != 0 { return result }
        }

        // Phase 2: stream events
        return streamPeripheralEvents(result, emit: emit)
    }

    /// Why `save(_:to:)` cannot write `path`, or nil when it can: the path is
    /// not a directory, and its directory exists and is writable (`save`
    /// replaces the file by a rename in that directory).
    static func unwritableReason(_ path: String) -> String? {
        let files = FileManager.default
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "it is a directory"
        }
        let directory = url.deletingLastPathComponent().path
        guard files.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "there is no directory \(directory)"
        }
        return files.isWritableFile(atPath: directory) ? nil : "the directory \(directory) is not writable"
    }

    /// Write `config` to `path` as pretty-printed JSON, replacing the file
    /// whole or not at all.
    static func save(_ config: PeripheralConfig, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func runPeriphClone(_ args: [String], emit: @escaping @Sendable (CommandOutput) -> Void = { _ in }) -> CommandResult {
        var result = CommandResult()
        let cloneOpts = Self.targetingOptionsWithValue.union(["-o", "--save"])
        // Checked before connecting, which may replace the connected device.
        let savePath: String?
        do {
            savePath = try optionValue(args, short: "-o", long: "--save", optionsWithValue: cloneOpts)
        } catch {
            return Self.invalidArguments("\(error)")
        }
        if let savePath, let problem = Self.unwritableReason(savePath) {
            return Self.invalidArguments("cannot save to '\(savePath)': \(problem)")
        }

        let connectResult = ensureConnected(args: args, optionsWithValue: cloneOpts)
        guard connectResult.exitCode == 0 else { return connectResult }

        result.infos.append("snapshotting GATT tree...")

        var clonedServices: [ServiceDefinition] = []
        var clonedName: String = "blew-clone"
        var initialValues: [BLEUUID: Data] = [:]
        // The operation writes only these and the values above. After an
        // interrupt or a timeout it may still run (waitInterruptible gives up
        // on it after 2 s), so they are read only once it completed.
        var snapFailure: (message: String, exitCode: Int32)?
        var refusedReads: [String] = []

        let snapOperation: () async -> Void = { [self] in
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
                            // A device that refuses the read gives a clone
                            // without an initial value; a cancellation, a
                            // timeout or a lost connection ends the snapshot.
                            do {
                                let data = try await manager.readCharacteristic(char.uuid)
                                valueStr = data.map { String(format: "%02x", $0) }.joined()
                                valueFmt = "hex"
                                initialValues[charUUID] = data
                            } catch BLEError.readFailed(let reason) {
                                refusedReads.append("\(char.uuid): \(reason)")
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
                // waitInterruptible reports the interrupt or the timeout.
            } catch let error as BLEUUID.ParseError {
                snapFailure = ("the device reported an \(error.localizedDescription)", BlewExitCode.operationFailed.code)
            } catch {
                snapFailure = (error.localizedDescription, BlewExitCode(for: error).code)
            }
        }

        switch waitInterruptible(snapOperation, timeout: globals.timeout ?? 15.0) {
        case .completed: break
        case .interrupted: result.exitCode = BlewExitCode.interrupted.code; return result
        case .timedOut:
            result.errors.append("GATT snapshot timed out")
            result.exitCode = BlewExitCode.timeout.code
            return result
        }
        if let snapFailure {
            result.errors.append(snapFailure.message)
            result.exitCode = snapFailure.exitCode
            return result
        }
        for refused in refusedReads {
            result.infos.append("cloned without an initial value, the device refused the read of \(refused)")
        }

        _ = runDisconnect([])

        if let path = savePath {
            do {
                try Self.save(PeripheralConfig(name: clonedName, services: clonedServices), to: path)
                result.infos.append("saved config to \(path)")
            } catch {
                result.errors.append("cannot save to '\(path)': \(error.localizedDescription)")
                result.exitCode = BlewExitCode.operationFailed.code
                return result
            }
        }

        let serviceUUIDs = clonedServices.map { $0.uuid }
        let peripheral = BLEPeripheral.shared
        backgroundPeriphTask?.cancel()
        backgroundPeriphTask = nil

        let startOperation: () async -> Void = {
            do {
                result.infos.append("configuring \(clonedServices.count) cloned service(s)...")
                try await peripheral.configure(services: clonedServices)

                for (uuid, data) in initialValues {
                    _ = try? peripheral.updateValue(data, forCharacteristic: uuid)
                }

                try await peripheral.startAdvertising(name: clonedName, serviceUUIDs: serviceUUIDs)
                result.output.append(.peripheralSummary(PeriphSummaryResult(
                    name: clonedName, serviceUUIDs: serviceUUIDs.map(\.string), services: clonedServices
                )))
            } catch is CancellationError {
                // handled below
            } catch {
                result.fail(error)
            }
        }

        switch waitInterruptible(startOperation, timeout: globals.timeout ?? 15.0) {
        case .interrupted:
            peripheral.stopAdvertising()
            result.exitCode = BlewExitCode.interrupted.code
            return result
        case .timedOut:
            peripheral.stopAdvertising()
            result.errors.append("advertising failed to start (timed out)")
            result.exitCode = BlewExitCode.timeout.code
            return result
        case .completed:
            if result.exitCode != 0 { return result }
        }

        return streamPeripheralEvents(result, emit: emit)
    }

    /// Phase 2 of `periph adv` and `periph clone`, once advertising has
    /// started; `startup` is what phase 1 gathered. In the REPL, `exec` and
    /// MCP the events stream from a background task and `startup` returns at
    /// once. A CLI command renders `startup` (the summary of what is
    /// advertised) before streaming, because the stream ends only with
    /// Ctrl-C, and returns what happened after that.
    private func streamPeripheralEvents(
        _ startup: CommandResult, emit: @escaping @Sendable (CommandOutput) -> Void
    ) -> CommandResult {
        let peripheral = BLEPeripheral.shared
        if isInteractiveMode {
            var result = startup
            backgroundPeriphTask = Task {
                let eventStream = peripheral.events()
                for await event in eventStream {
                    let ts = ISO8601DateFormatter.shared.string(from: Date())
                    emit(.peripheralEvent(PeriphEventRecord(timestamp: ts, event: event)))
                }
            }
            result.output.append(.message("Advertising in background. Use 'periph stop' to stop."))
            return result
        }

        renderer.renderResult(startup)
        var result = CommandResult()
        // Bluetooth leaving poweredOn ends advertising, and with it the
        // command. Read only after waitInterruptible returned .completed,
        // which means the operation has finished.
        var bluetoothLost: BLEError?
        let eventOperation: () async -> Void = {
            let eventStream = peripheral.events()
            // Bluetooth may have left poweredOn (and come back) before the
            // stream existed; in a one-shot command nothing else stops
            // advertising.
            if !peripheral.isAdvertising() {
                let state = peripheral.bluetoothState()
                bluetoothLost = state == .poweredOn
                    ? .bluetoothUnavailable("Bluetooth was reset and advertising stopped")
                    : BLEError.unavailable(state)
                return
            }
            for await event in eventStream {
                let ts = ISO8601DateFormatter.shared.string(from: Date())
                emit(.peripheralEvent(PeriphEventRecord(timestamp: ts, event: event)))
                if case .stateChanged(let state) = event, state != .poweredOn {
                    bluetoothLost = BLEError.unavailable(state)
                    break
                }
                if Task.isCancelled { break }
            }
        }
        switch waitInterruptible(eventOperation) {
        case .interrupted:
            peripheral.stopAdvertising()
            result.output.append(.message("Stopped advertising."))
            result.exitCode = BlewExitCode.interrupted.code
        case .completed:
            if let error = bluetoothLost {
                result.errors.append(error.localizedDescription)
                result.exitCode = error.exitCode
            }
        case .timedOut:
            break
        }
        return result
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
        let fmt: ValueFormat
        do {
            fmt = try valueFormat(args, optionsWithValue: ["-f", "--format"])
        } catch {
            return Self.invalidArguments("\(error)")
        }

        let charUUID: BLEUUID
        do {
            charUUID = try resolvePeriphCharacteristic(charInput)
        } catch {
            result.errors.append(error.localizedDescription)
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        guard let data = DataFormatter.parse(valueStr, as: fmt) else {
            result.errors.append("invalid value '\(valueStr)' for format '\(fmt.rawValue)'")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        do {
            try BLEPeripheral.shared.updateValue(data, forCharacteristic: charUUID)
            result.infos.append("set \(BLENames.displayUUID(charUUID.string, category: .characteristic)) = \(DataFormatter.format(data, as: fmt))")
        } catch {
            result.fail(error)
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
        let fmt: ValueFormat
        do {
            fmt = try valueFormat(args, optionsWithValue: ["-f", "--format"])
        } catch {
            return Self.invalidArguments("\(error)")
        }

        let charUUID: BLEUUID
        do {
            charUUID = try resolvePeriphCharacteristic(charInput)
        } catch {
            result.errors.append(error.localizedDescription)
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        guard let data = DataFormatter.parse(valueStr, as: fmt) else {
            result.errors.append("invalid value '\(valueStr)' for format '\(fmt.rawValue)'")
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }

        do {
            let name = BLENames.displayUUID(charUUID.string, category: .characteristic)
            switch try BLEPeripheral.shared.updateValue(data, forCharacteristic: charUUID) {
            case .notified:
                result.infos.append("sent notification on \(name)")
            case .queued(let pending):
                result.infos.append("queued notification on \(name) (\(pending) waiting for the Bluetooth transmit queue)")
            case .stored:
                result.infos.append("set \(name); no central is subscribed, so nothing was notified")
            }
        } catch {
            result.fail(error)
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
            "\"\(input)\" matches several characteristics: "
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
