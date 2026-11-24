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
    /// The device switches made while `collectingDeviceSwitches` runs; nil
    /// outside it, when `reportDeviceSwitch` writes each to stderr.
    private var collectedDeviceSwitches: [DeviceSwitch]?
    /// The caller's request to stop the command that is running, besides
    /// SIGINT; set only inside `run(stoppingOn:_:)`.
    private var stopRequest: StopRequest?
    private var backgroundPeriphTask: Task<Void, Never>?
    private let backgroundSubscriptions = BackgroundSubscriptions()
    /// The process's signal state; tests pass an instance of their own.
    let signals: ProcessSignals

    init(globals: GlobalOptions, manager: BLECentral? = nil, isInteractiveMode: Bool = false,
         renderer: OutputRenderer? = nil, signals: ProcessSignals = .shared) {
        self.globals = globals
        self.signals = signals
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
                output.write(TextLine("[\(i + 1)] \(cmd)"))
            }
            return 0
        }

        var firstError: Int32 = 0
        for cmd in commands {
            let outcome = runScriptCommand(cmd)
            if outcome.endsScript(keepGoing: keepGoing) { return outcome.code }
            if firstError == 0 { firstError = outcome.code }
        }
        return firstError
    }

    /// How one script command ended (`runScriptCommand`).
    struct ScriptCommandOutcome: Equatable {
        /// Its exit code, `SignalPolicy.exitCode(after:stopRequested:)`.
        let code: Int32
        /// Whether a stop was requested by the time it finished.
        let stopRequested: Bool

        /// Whether the script ends here, with `code`: on a stop, also with
        /// `--keep-going` and when the command failed, since the next
        /// command may have no wait to see the stop; and on a failure
        /// without `--keep-going`.
        func endsScript(keepGoing: Bool) -> Bool {
            stopRequested || (code != BlewExitCode.success.code && !keepGoing)
        }
    }

    /// Run one command of a script (`exec`, or a REPL session, typed or
    /// piped) as a signal span of its own. A stop requested before it
    /// starts (a Ctrl-C between two `exec` commands, which the outer span
    /// keeps) keeps it from running, with 130. A stop requested while it
    /// runs makes a success 130, even if its last operation finished as the
    /// stop arrived; a failure keeps its own code. Once a signal has begun
    /// the exit, the command does not start: `commandStarted` waits for the
    /// signal's exit instead.
    func runScriptCommand(_ line: String) -> ScriptCommandOutcome {
        signals.commandStarted()
        if isStopRequested {
            signals.commandFinished()
            return ScriptCommandOutcome(code: BlewExitCode.interrupted.code, stopRequested: true)
        }
        let result = dispatch(line)
        // Read under the lock that closes the span (the flag of an
        // outermost span clears as it closes), plus the StopRequest of an
        // enclosing `run(stoppingOn:_:)`.
        let stopRequested = signals.commandFinished() || stopRequest?.reason != nil
        return ScriptCommandOutcome(
            code: SignalPolicy.exitCode(after: result.exitCode, stopRequested: stopRequested),
            stopRequested: stopRequested)
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
        /// A help line: two spaces, `names` in bold a space apart, then
        /// `arguments`.
        func command(_ names: String..., arguments: String = "") -> TextLine {
            var line = TextLine("  ")
            for (i, name) in names.enumerated() {
                if i > 0 { line.append(" ") }
                line.append(name, .bold)
            }
            if !arguments.isEmpty { line.append(" " + arguments) }
            return line
        }
        var quit = command("quit")
        quit.append("/")
        quit.append("exit", .bold)
        let targeting = "[-n <name>] [-S <uuid>] [-i <id>]"
        output.write([
            TextLine("Available commands:"),
            command("scan", arguments: "\(targeting) [-R <dBm>] [-m <mfr>] [-p <strategy>] [-t <sec>] [-w]"),
            command("connect", arguments: "\(targeting) [<id>]"),
            command("disconnect"),
            command("status"),
            command("gatt", "svcs", arguments: targeting),
            command("gatt", "tree", arguments: "\(targeting) [-d] [-r [-f <fmt>]]"),
            command("gatt", "chars", arguments: "\(targeting) [-r [-f <fmt>]] <service>"),
            command("gatt", "desc", arguments: "\(targeting) <char>"),
            command("gatt", "info", arguments: "<char>"),
            command("read", arguments: "\(targeting) [-f <fmt>] <char>"),
            command("write", arguments: "\(targeting) [-f <fmt>] [-r|-w] <char> <data>"),
            command("sub", arguments: "\(targeting) [-f <fmt>] [-d <sec>] [-c <n>] [-b] <char>"),
            command("sub", "stop", arguments: "[<char>]"),
            command("sub", "status"),
            command("periph", "adv", arguments: "[-n <name>] [-S <uuid>] [--config <file>] [-t <sec>]"),
            command("periph", "clone", arguments: "\(targeting) [--save <file>]"),
            command("periph", "stop"),
            command("periph", "set", arguments: "[-f <fmt>] <char> <value>"),
            command("periph", "notify", arguments: "[-f <fmt>] <char> <value>"),
            command("nus", arguments: "\(targeting) [-s <text>] [--file <path>] [-e <text>] [-d <sec>] [--pty] [-l <port>] [--reconnect] [-r|-w]"),
            command("sleep", arguments: "<seconds>"),
            command("help"),
            quit,
        ])
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

    func runScan(_ args: [String]) -> CommandResult {
        let arguments: ParsedArguments
        let target: DeviceTarget
        let duration: TimeInterval?
        do {
            arguments = try CommandSyntax.scan.parse(args)
            target = try DeviceTarget(arguments)
            duration = try commandTimeout(arguments.value(.timeout))
        } catch {
            return CommandResult(failing: error)
        }

        if arguments.flag(.watch) {
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

    /// A command's timeout: `local` (the command's own `-t`, as in
    /// `scan -t 3`), else the global `-t`; nil when neither is given. Throws
    /// when the value is not a duration `isValidDuration` accepts (finite,
    /// 0 to `maxDuration` seconds): a NaN deadline never passes, and a scan
    /// stop is scheduled with a nanosecond sleep that a huge value overflows.
    private func commandTimeout(_ local: String?) throws -> TimeInterval? {
        guard let text = local ?? globals.timeout.map({ "\($0)" }) else { return nil }
        guard let seconds = Double(text), Self.isValidDuration(seconds) else {
            throw InvalidArgument("invalid timeout '\(text)' (use 0 to \(Int(Self.maxDuration)) seconds)")
        }
        return seconds
    }

    /// The scan duration auto-connect uses: the global `-t`, else 5 seconds.
    private func autoConnectScanDuration() throws -> TimeInterval {
        try commandTimeout(nil) ?? 5.0
    }

    /// How long `periph adv` waits for advertising to start (configuring
    /// its services, then the start itself): its `-t`, else the global
    /// `-t`, else 15 seconds.
    func advertisingStartTimeout(_ arguments: ParsedArguments) throws -> TimeInterval {
        try commandTimeout(arguments.value(.timeout)) ?? 15.0
    }

    /// The result of a command that cannot start for the reason `message`
    /// gives, with exit code 6. The message is a literal: a caught error
    /// goes to `CommandResult(failing:)`, which takes its exit code from its
    /// type, and a message built from values is an `InvalidArgument`.
    static func invalidArguments(_ message: StaticString) -> CommandResult {
        var result = CommandResult()
        result.errors.append("\(message)")
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
        let interactive = StandardErrorLog.isTerminal
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
                for try await device in stream {
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

        guard StandardOutput.isTerminal else {
            return Self.invalidArguments("scan --watch in text mode requires an interactive terminal; use -o kv for piped output")
        }

        let display = ScanWatchDisplay(formatter: output)
        display.start()

        var scanFailure: Error?
        var results = ScanResults()

        let operation: () async -> Void = { [self] in
            do {
                let stream = try await manager.scan(timeout: timeout, allowDuplicates: true)
                for try await device in stream {
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
                for try await device in stream {
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
        let target: DeviceTarget
        do {
            let arguments = try CommandSyntax.connect.parse(args)
            target = try DeviceTarget(arguments)
            if let id = arguments.positionals.first {
                guard target == DeviceTarget() else {
                    return Self.invalidArguments("name the device as an argument or with targeting options, not both")
                }
                return ensureConnected(to: DeviceTarget(id: id), reconnect: true)
            }
        } catch {
            return CommandResult(failing: error)
        }
        return ensureConnected(to: target, reconnect: true)
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

    func runDisconnect(_ args: [String]) -> CommandResult {
        if let failure = Self.checkArguments(args, .disconnect) { return failure }
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
        if let failure = Self.checkArguments(args, .status) { return failure }
        var result = CommandResult()

        let operation: () async -> Void = { [self] in
            let status = await manager.status()
            result.output.append(.connectionStatus(status))
        }
        result.debugs.append("scan results dropped while the event queue was full: \(manager.droppedScanResults)")

        if case .interrupted = waitInterruptible(operation) {
            result.exitCode = BlewExitCode.interrupted.code
        }
        return result
    }

    /// The failure of a command that reads nothing from its arguments when
    /// `args` does not fit its `syntax`; nil when they do.
    static func checkArguments(_ args: [String], _ syntax: CommandSyntax) -> CommandResult? {
        do {
            _ = try syntax.parse(args)
            return nil
        } catch {
            return CommandResult(failing: error)
        }
    }

    func runSleep(_ args: [String]) -> CommandResult {
        var result = CommandResult()
        let text: String
        do {
            text = try CommandSyntax.sleep.parse(args).positionals[0]
        } catch {
            return CommandResult(failing: error)
        }
        guard let seconds = Double(text) else {
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

    /// `gatt <sub>`. The subcommand is the first positional, so options may
    /// come before it (`gatt -n foo tree`); once it is known, the arguments
    /// are read again with its own options and positionals
    /// (`CommandSyntax.gattSubcommands`), so `gatt svcs -d` is an unknown
    /// option and `gatt svcs x` an unexpected argument.
    func runGATT(_ args: [String]) -> CommandResult {
        let usage = CommandOutput.message("Usage: gatt <svcs|tree|chars|desc|info>")
        let sub: String
        let arguments: ParsedArguments
        let target: DeviceTarget
        do {
            guard let first = try CommandSyntax.gatt.subcommand(in: args) else {
                var result = Self.invalidArguments("missing subcommand")
                result.output.append(usage)
                return result
            }
            guard let syntax = CommandSyntax.gattSubcommands[first] else {
                var result = CommandResult(failing: InvalidArgument("unknown gatt subcommand '\(first)'"))
                result.output.append(usage)
                return result
            }
            sub = first
            arguments = try syntax.parse(args)
            if sub == "info" {
                return runGATTInfo(arguments.positionals[1])
            }
            target = try DeviceTarget(arguments)
        } catch {
            return CommandResult(failing: error)
        }

        // Arguments are checked before auto-connect, which may replace the
        // connected device; the syntax gives `chars` and `desc` their operand.
        let operand = arguments.positionals.dropFirst().first
        let includeDescriptors = sub == "tree" && arguments.flag(.descriptors)
        let includeValues = (sub == "tree" || sub == "chars") && arguments.flag(.readValues)
        let valueFormat: ValueFormat?
        do {
            // Only `tree` and `chars` take `-f`; asking another syntax for it traps.
            valueFormat = sub == "tree" || sub == "chars" ? try Self.listingFormat(arguments) : nil
        } catch {
            return CommandResult(failing: error)
        }

        let connectResult = ensureConnected(to: target)
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
                    let tree = try await manager.discoverTree(includeDescriptors: includeDescriptors)
                    var treeServices: [GATTTreeService] = []
                    for service in tree {
                        var treeChars: [GATTTreeCharacteristic] = []
                        for char in service.characteristics {
                            let charName = BLENames.name(for: char.uuid, category: .characteristic)
                            let listed = includeValues && char.properties.contains("read")
                                ? try await readListedValue(char.uuid, format: valueFormat) : nil
                            let descRows = char.descriptors.map { desc in
                                DescriptorRow(uuid: desc.uuid, name: BLENames.name(for: desc.uuid, category: .descriptor))
                            }
                            treeChars.append(GATTTreeCharacteristic(
                                uuid: char.uuid, name: charName,
                                properties: char.properties,
                                listed: listed,
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
                    guard let svcInput = operand else { preconditionFailure("checked before connecting") }
                    let svcUUID: String
                    switch resolveService(svcInput) {
                    case .resolved(let uuid): svcUUID = uuid
                    case .ambiguous(let uuids):
                        result.errors.append("ambiguous service '\(svcInput)' -- matches: \(uuids.joined(separator: ", "))")
                        result.exitCode = BlewExitCode.invalidArguments.code
                        return
                    case .notFound: svcUUID = svcInput
                    }
                    let chars = try await manager.discoverCharacteristics(forService: svcUUID)
                    var charRows: [CharacteristicRow] = []
                    for char in chars {
                        let name = BLENames.name(for: char.uuid, category: .characteristic)
                        let listed = includeValues && char.properties.contains("read")
                            ? try await readListedValue(char.uuid, format: valueFormat) : nil
                        charRows.append(CharacteristicRow(uuid: char.uuid, name: name,
                                                          properties: char.properties, listed: listed))
                    }
                    result.output.append(.characteristics(charRows))

                case "desc":
                    guard let charInput = operand else { preconditionFailure("checked before connecting") }
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
        // Arguments are checked before auto-connect, which may replace the connected device.
        let arguments: ParsedArguments
        let target: DeviceTarget
        let fmt: ValueFormat
        do {
            arguments = try CommandSyntax.read.parse(args)
            target = try DeviceTarget(arguments)
            fmt = try Self.valueFormat(arguments)
        } catch {
            return CommandResult(failing: error)
        }
        let charInput = arguments.positionals[0]
        let connectResult = ensureConnected(to: target)
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
        // Arguments are checked before auto-connect, which may replace the connected device.
        let arguments: ParsedArguments
        let target: DeviceTarget
        let fmt: ValueFormat
        do {
            arguments = try CommandSyntax.write.parse(args)
            target = try DeviceTarget(arguments)
            fmt = try Self.valueFormat(arguments)
        } catch {
            return CommandResult(failing: error)
        }
        let charInput = arguments.positionals[0]
        let dataStr = arguments.positionals[1]
        guard let data = DataFormatter.parse(dataStr, as: fmt) else {
            return CommandResult(failing: InvalidArgument("invalid data '\(dataStr)' for format '\(fmt.rawValue)'"))
        }
        let writeType: WriteType
        if arguments.flag(.withResponse) {
            writeType = .withResponse
        } else if arguments.flag(.withoutResponse) {
            writeType = .withoutResponse
        } else {
            writeType = .auto
        }
        let connectResult = ensureConnected(to: target)
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
        if let first = args.first {
            switch first {
            case "stop":   return runSubStop(Array(args.dropFirst()))
            case "status": return runSubStatus(Array(args.dropFirst()))
            default: break
            }
        }

        var result = CommandResult()
        // Arguments are checked before auto-connect, which may replace the connected device.
        let arguments: ParsedArguments
        let target: DeviceTarget
        let duration: TimeInterval?
        let fmt: ValueFormat
        let maxCount: Int?
        do {
            arguments = try (foregroundOnly ? CommandSyntax.subForeground : CommandSyntax.sub).parse(args)
            target = try DeviceTarget(arguments)
            duration = try arguments.value(.duration).map { text in
                guard let seconds = Double(text), Self.isValidDuration(seconds) else {
                    throw InvalidArgument("invalid duration '\(text)' (use 0 to \(Int(Self.maxDuration)) seconds)")
                }
                return seconds
            }
            fmt = try Self.valueFormat(arguments)
            maxCount = try Self.notificationCount(arguments)
        } catch {
            return CommandResult(failing: error)
        }
        let background = !foregroundOnly && arguments.flag(.background)
        let charInput = arguments.positionals[0]
        if background, !isInteractiveMode {
            return Self.invalidArguments("-b is only available in interactive mode")
        }
        let connectResult = ensureConnected(to: target)
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
            let capturedRenderer = self.renderer
            backgroundSubscriptions.start(charUUID) {
                do {
                    let stream = try await Self.withDeadline(setupTimeout) {
                        try await manager.subscribe(characteristicUUID: charUUID)
                    }
                    try await Self.forEachNotification(stream, maxCount: maxCount, duration: duration, dropped: { total in
                        capturedRenderer.renderLive("sub \(NotificationDrops(char: charUUID, total: total).text)")
                    }) { data in
                        capturedRenderer.renderLive("[\(charUUID)] \(DataFormatter.format(data, as: fmt))")
                    }
                } catch is CancellationError {
                    // stopped
                } catch {
                    capturedRenderer.renderLive("sub error [\(charUUID)]: \(error.localizedDescription)")
                }
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
                try await Self.forEachNotification(stream, maxCount: maxCount, duration: duration, dropped: { total in
                    emit(.notificationsDropped(NotificationDrops(char: charUUID, total: total)))
                }) { data in
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
        let positionals: [String]
        do {
            positionals = try CommandSyntax.subStop.parse(args).positionals
        } catch {
            return CommandResult(failing: error)
        }
        if let charInput = positionals.first {
            let charUUID: String
            switch resolveCharacteristic(charInput) {
            case .resolved(let uuid): charUUID = uuid
            case .ambiguous(let uuids):
                result.errors.append("ambiguous characteristic '\(charInput)' -- matches: \(uuids.joined(separator: ", "))")
                result.exitCode = BlewExitCode.invalidArguments.code
                return result
            case .notFound: charUUID = charInput
            }
            guard backgroundSubscriptions.stop(charUUID) else {
                result.errors.append("no background subscription for '\(charUUID)'")
                result.exitCode = BlewExitCode.notFound.code
                return result
            }
            result.output.append(.message("Stopped subscription for \(BLENames.displayUUID(charUUID, category: .characteristic))."))
        } else {
            guard backgroundSubscriptions.stopAll() else {
                result.output.append(.message("No active background subscriptions."))
                return result
            }
            result.output.append(.message("Stopped all background subscriptions."))
        }
        return result
    }

    func runSubStatus(_ args: [String]) -> CommandResult {
        if let failure = Self.checkArguments(args, .subStatus) { return failure }
        var result = CommandResult()
        let uuids = backgroundSubscriptions.characteristics
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
    /// the error the stream ends with (the connection ended). `dropped` gets
    /// the number of notifications the stream dropped so far because
    /// `handle` did not keep up (`NotificationStream.capacity`): once when
    /// the first drops are seen, and with the total when the subscription
    /// ends, however it ends, if more were dropped since.
    static func forEachNotification(_ stream: NotificationStream, maxCount: Int?, duration: TimeInterval?,
                                    dropped: @escaping @Sendable (Int) -> Void = { _ in },
                                    _ handle: @escaping @Sendable (Data) -> Void) async throws {
        let reported = Locked(0)
        defer {
            let total = stream.droppedCount
            if total > reported.value { dropped(total) }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var count = 0
                for try await data in stream {
                    if reported.value == 0 {
                        let total = stream.droppedCount
                        if total > 0 {
                            reported.set(total)
                            dropped(total)
                        }
                    }
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
    ///
    /// A stop requested by a signal, or by the exit beginning, while `body`
    /// ran makes a success 130 (`SignalPolicy.exitCode(after:stopRequested:)`),
    /// as for a script command. The request's own stop does not: the caller maps its
    /// outcome (`MCPServer.execute`: no response for a cancelled call, and
    /// a success that outran its budget stands).
    func run(stoppingOn request: StopRequest, _ body: () -> CommandResult) -> CommandResult {
        let outer = stopRequest
        stopRequest = request
        defer { stopRequest = outer }
        signals.commandStarted()
        var result = body()
        // Read under the lock that closes the span, as in `runScriptCommand`.
        let stopRequested = signals.commandFinished()
        result.exitCode = SignalPolicy.exitCode(after: result.exitCode, stopRequested: stopRequested)
        return result
    }

    /// Whether the running command was asked to stop: by a SIGINT, by a
    /// signal that began the exit (`ProcessSignals.stopRequested`), or by
    /// the `StopRequest` attached with `run(stoppingOn:_:)`.
    private var isStopRequested: Bool {
        signals.stopRequested || stopRequest?.reason != nil
    }

    enum CommandOutcome { case completed, interrupted, timedOut }

    /// Run `operation` in a Task and block the calling thread until it
    /// finishes, polling every 50 ms. A stop (`isStopRequested`: a Ctrl-C
    /// interrupt, a signal exit begun, or the attached `StopRequest` set):
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
        signals.commandStarted()
        defer { signals.commandFinished() }
        if isStopRequested { return .interrupted }
        let finished = DispatchSemaphore(value: 0)
        let task = Task {
            defer { finished.signal() }
            await operation()
        }
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            if isStopRequested {
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

    /// Make sure the device `target` names is connected before an
    /// operation. `AutoConnectPlan` decides:
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
    func ensureConnected(to target: DeviceTarget,
                         defaultFilter: DeviceFilter = DeviceFilter(), reconnect: Bool = false) -> CommandResult {
        let connected = connectedDevice()
        let deviceId: String
        switch AutoConnectPlan.make(target: target, defaultFilter: defaultFilter, connected: connected,
                                    scanned: lastScanResults.map(\.identifier), reconnect: reconnect) {
        case .useConnected:
            return CommandResult()
        case .noTarget:
            return Self.invalidArguments("not connected -- specify a device with --id or --name")
        case .unresolvedIdentifier(let input, let failure):
            return unresolvedIdentifier(input, failure)
        case .connect(let id):
            deviceId = id
        case .scan(let filter, let pick):
            let duration: TimeInterval
            do {
                duration = try autoConnectScanDuration()
            } catch {
                return CommandResult(failing: error)
            }
            var (devices, result) = scanForDevices(timeout: duration, filter: filter)
            guard result.exitCode == 0 else { return result }
            guard let device = choose(pick, from: devices, into: &result) else { return result }
            deviceId = device.identifier
        }

        // BLECentral.connect disconnects the connected device first, unless
        // it fails before (Bluetooth off, an identifier CoreBluetooth does
        // not know): report a switch only once the old device is gone.
        let result = connect(to: deviceId)
        if let replaced = DeviceSwitch(replacing: connected, with: deviceId),
           connectedDevice()?.id.caseInsensitiveCompare(replaced.from) != .orderedSame {
            reportDeviceSwitch(replaced)
        }
        return result
    }

    /// Tell the user or agent that auto-connect replaced the connected
    /// device, so they know which device the command acted on: on stderr at
    /// every verbosity, in text and kv alike, or, inside
    /// `collectingDeviceSwitches`, into its result.
    func reportDeviceSwitch(_ replaced: DeviceSwitch) {
        if collectedDeviceSwitches != nil {
            collectedDeviceSwitches?.append(replaced)
        } else {
            StandardErrorLog.write("", replaced.notice)
        }
    }

    /// Run `body`, returning its value and the device switches made while it
    /// ran instead of writing them to stderr (the MCP server returns them in
    /// the call's result).
    func collectingDeviceSwitches<T>(_ body: () -> T) -> (T, [DeviceSwitch]) {
        let outer = collectedDeviceSwitches
        collectedDeviceSwitches = []
        let value = body()
        let collected = collectedDeviceSwitches ?? []
        collectedDeviceSwitches = outer.map { $0 + collected }
        return (value, collected)
    }

    /// The error for a `-i` value that does not stand for one identifier.
    private func unresolvedIdentifier(_ input: String, _ failure: IdentifierFailure) -> CommandResult {
        switch failure {
        case .notAnIdentifier:
            return CommandResult(failing: InvalidArgument(
                "'\(input)' is not a device identifier or part of one (-i takes hex digits; select by name with -n)"))
        case .notFound:
            var result = CommandResult()
            result.errors.append("device '\(input)' not found: no device of the last scan, and not the connected device, has an identifier containing it")
            result.exitCode = BlewExitCode.notFound.code
            return result
        case .ambiguous(let ids):
            var result = CommandResult()
            result.errors.append("ambiguous device '\(input)' -- matches:")
            for id in ids {
                let name = (lastScanResults + [connectedAdvertisement].compactMap { $0 })
                    .first { $0.identifier.caseInsensitiveCompare(id) == .orderedSame }?.name
                result.errors.append("  " + (name.map { "\($0) (\(id))" } ?? id))
            }
            result.exitCode = BlewExitCode.invalidArguments.code
            return result
        }
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

    // MARK: - Option values

    /// The `-f`/`--format` of `arguments`, hex when it is absent. Throws for
    /// a name that is not a `ValueFormat`.
    static func valueFormat(_ arguments: ParsedArguments) throws -> ValueFormat {
        try ValueFormat(parsing: arguments.value(.format) ?? "hex")
    }

    /// The `sub -c`/`--count` of `arguments`, nil (no limit) when it is
    /// absent. Throws for anything but a whole number of at least 1.
    static func notificationCount(_ arguments: ParsedArguments) throws -> Int? {
        guard let text = arguments.value(.count) else { return nil }
        guard let count = Int(text), count >= 1 else {
            throw InvalidArgument("invalid count '\(text)' (use a whole number of at least 1)")
        }
        return count
    }
}

// MARK: - Device & characteristic resolution

extension CommandRouter {
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
    /// The `-f`/`--format` of `gatt chars|tree`: nil when it is absent, so
    /// values are decoded by their Bluetooth SIG definition. Throws when it
    /// is given without `-r` (there is no value to format), for `raw` and
    /// for an unknown name.
    static func listingFormat(_ arguments: ParsedArguments) throws -> ValueFormat? {
        guard let name = arguments.value(.format) else { return nil }
        guard arguments.flag(.readValues) else {
            throw InvalidArgument("-f/--format formats read values; it needs -r/--read")
        }
        return try ValueFormat(parsingForListing: name)
    }

    /// Reads `uuid` for a listing. A read the device refuses fails only this
    /// value (`listedValue(failedRead:)`).
    func readListedValue(_ uuid: String, format: ValueFormat?) async throws -> ListedValue {
        let data: Data
        do {
            data = try await manager.readCharacteristic(uuid)
        } catch {
            return try Self.listedValue(failedRead: error)
        }
        return Self.listedValue(data, uuid: uuid, format: format)
    }

    /// The listing value of a read that threw `error`. Only the device
    /// refusing this characteristic (`BLEError.readFailed`) fails this row
    /// alone; any other error (the link lost, Bluetooth off, cancellation)
    /// is rethrown and ends the listing with its own exit code.
    static func listedValue(failedRead error: Error) throws -> ListedValue {
        guard case BLEError.readFailed(let reason) = error else { throw error }
        return .failed("read failed: \(reason)")
    }

    /// The listing value of `data` read from `uuid`: in `format` when one
    /// is given (a value that does not fit it is `.failed`), otherwise
    /// decoded by its Bluetooth SIG definition, or hex when it has none.
    static func listedValue(_ data: Data, uuid: String, format: ValueFormat?) -> ListedValue {
        if let format {
            do {
                return .value(try DataFormatter.formatExactly(data, as: format))
            } catch {
                return .failed(error.message)
            }
        }
        let decoded = GATTDecoder.decode(data, uuid: uuid) ?? DataFormatter.format(data, as: .hex)
        let parts = decoded.components(separatedBy: " | ")
        return parts.count > 1 ? .fields(parts.map { splitFieldPart($0) }) : .value(decoded)
    }

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
        let arguments: ParsedArguments
        let startTimeout: TimeInterval
        do {
            arguments = try CommandSyntax.periphAdv.parse(args)
            startTimeout = try advertisingStartTimeout(arguments)
        } catch {
            return CommandResult(failing: error)
        }
        let configPath = arguments.value(.config)
        let nameArg = arguments.value(.name)
        let serviceArgs = arguments.values(.service)

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
            // A service UUID or a config file blew cannot use is an argument
            // it cannot use, whatever the error's type.
            return CommandResult(failing: InvalidArgument(error.localizedDescription))
        }

        if services.isEmpty && serviceUUIDs.isEmpty {
            return Self.invalidArguments("no services defined -- use --config <file> or -S <uuid>")
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

        switch waitInterruptible(startOperation, timeout: startTimeout) {
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
        // Checked before connecting, which may replace the connected device.
        let target: DeviceTarget
        let savePath: String?
        do {
            let arguments = try CommandSyntax.periphClone.parse(args)
            target = try DeviceTarget(arguments)
            savePath = arguments.value(.save)
            if let savePath, let problem = Self.unwritableReason(savePath) {
                throw InvalidArgument("cannot save to '\(savePath)': \(problem)")
            }
        } catch {
            return CommandResult(failing: error)
        }

        let connectResult = ensureConnected(to: target)
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
        if let failure = Self.checkArguments(args, .periphStop) { return failure }
        var result = CommandResult()
        backgroundPeriphTask?.cancel()
        backgroundPeriphTask = nil
        BLEPeripheral.shared.stopAdvertising()
        result.output.append(.message("Stopped advertising."))
        return result
    }

    /// The characteristic, value and format of `periph set` and
    /// `periph notify`. Throws an `InvalidArgument` for arguments it cannot
    /// use, a characteristic it cannot resolve among them.
    private func parsePeriphValue(_ args: [String], _ subcommand: CommandSyntax.PeriphValueSubcommand) throws
        -> (char: BLEUUID, data: Data, format: ValueFormat) {
        let arguments = try CommandSyntax.periphValue(subcommand).parse(args)
        let positional = arguments.positionals
        let fmt = try Self.valueFormat(arguments)
        let charUUID: BLEUUID
        do {
            charUUID = try resolvePeriphCharacteristic(positional[0])
        } catch {
            throw InvalidArgument(error.localizedDescription)
        }
        guard let data = DataFormatter.parse(positional[1], as: fmt) else {
            throw InvalidArgument("invalid value '\(positional[1])' for format '\(fmt.rawValue)'")
        }
        return (charUUID, data, fmt)
    }

    func runPeriphSet(_ args: [String]) -> CommandResult {
        var result = CommandResult()
        let (charUUID, data, fmt): (BLEUUID, Data, ValueFormat)
        do {
            (charUUID, data, fmt) = try parsePeriphValue(args, .set)
        } catch {
            return CommandResult(failing: error)
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
        let (charUUID, data): (BLEUUID, Data)
        do {
            (charUUID, data, _) = try parsePeriphValue(args, .notify)
        } catch {
            return CommandResult(failing: error)
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
        if let failure = Self.checkArguments(args, .periphStatus) { return failure }
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
        let line = TextLine("\(frame) Scanning… \(String(format: "%.1f", elapsed))/\(String(format: "%.0f", timeout))s\(countStr)")
        StandardErrorLog.redraw(line, styled: false)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        StandardErrorLog.erase(.eraseLine)
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
        StandardErrorLog.erase(.eraseLinesAbove(previousLineCount))
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

        let rows = devices.map { d in
            TextTable.Row(cells: [
                d.identifier,
                d.name ?? "(unknown)",
                "\(d.rssi)",
                CommandRouter.rssiBar(d.rssi),
                d.serviceUUIDs.map { BLENames.displayUUID($0, category: .service) }.joined(separator: ", "),
            ])
        }
        let lines = [TextLine(header)]
            + TextTable.lines(headers: ["ID", "Name", "RSSI", "Signal", "Services"], rows: rows)

        // Replace the lines drawn last.
        StandardErrorLog.redraw(lines, replacing: previousLineCount, styled: formatter.styled)
        previousLineCount = lines.count
    }
}

extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
