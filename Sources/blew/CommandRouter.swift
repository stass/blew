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
        let help = """
        Available commands:
          scan        Scan for BLE devices
          connect     Connect to a device
          disconnect  Disconnect from current device
          status      Show connection status
          gatt        Inspect GATT services/characteristics
          read        Read a characteristic value
          write       Write to a characteristic
          sub         Subscribe to notifications/indications
          help        Show this help
          quit/exit   Exit the REPL
        """
        print(help)
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
        let scanTimeout = parseDoubleOption(args, short: "-t", long: "--timeout") ?? globals.timeout ?? 5.0
        let nameFilter = parseStringOption(args, short: "-n", long: "--name") ?? globals.name
        let rssiMin = parseIntOption(args, short: "-r", long: "--rssi-min") ?? globals.rssiMin

        let interactive = isatty(fileno(stderr)) != 0
        let spinner: ScanSpinner? = interactive ? ScanSpinner(timeout: scanTimeout) : nil
        if !interactive {
            output.printInfo("scanning for \(scanTimeout)s...")
        }
        spinner?.start()

        let semaphore = DispatchSemaphore(value: 0)
        var deviceMap: [String: DiscoveredDevice] = [:]
        var scanError: Int32 = 0

        Task {
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
            } catch {
                output.printError("\(error)")
                scanError = BlewExitCode.operationFailed.code
            }
            semaphore.signal()
        }

        semaphore.wait()
        spinner?.stop()

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
                    d.serviceUUIDs.joined(separator: ","),
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

        Task {
            do {
                try await manager.connect(deviceId: targetId, timeout: connectTimeout)
                output.printInfo("connected to \(targetId)")
            } catch let error as BLEError {
                output.printError(error.localizedDescription)
                exitCode = error.exitCode
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
            semaphore.signal()
        }

        semaphore.wait()
        return exitCode
    }

    func runDisconnect(_ args: [String]) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            do {
                try await manager.disconnect()
                output.printInfo("disconnected")
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
            semaphore.signal()
        }

        semaphore.wait()
        return exitCode
    }

    func runStatus(_ args: [String]) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)

        Task {
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
            semaphore.signal()
        }

        semaphore.wait()
        return 0
    }

    func runGATT(_ args: [String]) -> Int32 {
        let connectCode = ensureConnected()
        guard connectCode == 0 else { return connectCode }

        guard let sub = args.first else {
            output.printError("missing subcommand")
            print("Usage: gatt <svcs|tree|chars|desc>")
            return BlewExitCode.invalidArguments.code
        }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            do {
                switch sub {
                case "svcs":
                    let services = try await manager.discoverServices()
                    let headers = ["UUID", "Primary"]
                    let rows = services.map { [$0.uuid, $0.isPrimary ? "yes" : "no"] }
                    output.printTable(headers: headers, rows: rows)

                case "tree":
                    let includeDescriptors = args.contains("-d") || args.contains("--descriptors")
                    let tree = try await manager.discoverTree(includeDescriptors: includeDescriptors)
                    for service in tree {
                        output.print("Service: \(service.uuid)")
                        for char in service.characteristics {
                            let props = char.properties.joined(separator: ",")
                            output.print("  Char: \(char.uuid) [\(props)]")
                            for desc in char.descriptors {
                                output.print("    Desc: \(desc.uuid)")
                            }
                        }
                    }

                case "chars":
                    guard let svcInput = parseStringOption(Array(args.dropFirst()), short: "-S", long: "--service") else {
                        output.printError("missing --service UUID")
                        exitCode = BlewExitCode.invalidArguments.code
                        semaphore.signal()
                        return
                    }
                    let svcUUID: String
                    switch resolveService(svcInput) {
                    case .resolved(let uuid): svcUUID = uuid
                    case .ambiguous(let uuids):
                        output.printError("ambiguous service '\(svcInput)' — matches: \(uuids.joined(separator: ", "))")
                        exitCode = BlewExitCode.invalidArguments.code
                        semaphore.signal()
                        return
                    case .notFound: svcUUID = svcInput
                    }
                    let chars = try await manager.discoverCharacteristics(forService: svcUUID)
                    let headers = ["UUID", "Properties"]
                    let rows = chars.map { [$0.uuid, $0.properties.joined(separator: ",")] }
                    output.printTable(headers: headers, rows: rows)

                case "desc":
                    guard let charInput = parseStringOption(Array(args.dropFirst()), short: "-c", long: "--char") else {
                        output.printError("missing --char UUID")
                        exitCode = BlewExitCode.invalidArguments.code
                        semaphore.signal()
                        return
                    }
                    let charUUID: String
                    switch resolveCharacteristic(charInput) {
                    case .resolved(let uuid): charUUID = uuid
                    case .ambiguous(let uuids):
                        output.printError("ambiguous characteristic '\(charInput)' — matches: \(uuids.joined(separator: ", "))")
                        exitCode = BlewExitCode.invalidArguments.code
                        semaphore.signal()
                        return
                    case .notFound: charUUID = charInput
                    }
                    let descs = try await manager.discoverDescriptors(forCharacteristic: charUUID)
                    let headers = ["UUID"]
                    let rows = descs.map { [$0.uuid] }
                    output.printTable(headers: headers, rows: rows)

                default:
                    output.printError("unknown gatt subcommand '\(sub)'")
                    exitCode = BlewExitCode.invalidArguments.code
                }
            } catch let error as BLEError {
                output.printError(error.localizedDescription)
                exitCode = error.exitCode
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
            semaphore.signal()
        }

        semaphore.wait()
        return exitCode
    }

    func runRead(_ args: [String]) -> Int32 {
        let connectCode = ensureConnected()
        guard connectCode == 0 else { return connectCode }

        guard let charInput = parseStringOption(args, short: "-c", long: "--char") else {
            output.printError("missing --char UUID")
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
        let fmt = parseStringOption(args, short: "-F", long: "--format") ?? "hex"

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            do {
                let data = try await manager.readCharacteristic(charUUID)
                let formatted = DataFormatter.format(data, as: fmt)
                switch output.format {
                case .text:
                    output.print(formatted)
                case .kv:
                    output.printRecord(("char", charUUID), ("value", formatted), ("fmt", fmt))
                }
            } catch let error as BLEError {
                output.printError(error.localizedDescription)
                exitCode = error.exitCode
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
            semaphore.signal()
        }

        semaphore.wait()
        return exitCode
    }

    func runWrite(_ args: [String]) -> Int32 {
        let connectCode = ensureConnected()
        guard connectCode == 0 else { return connectCode }

        guard let charInput = parseStringOption(args, short: "-c", long: "--char") else {
            output.printError("missing --char UUID")
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
        guard let dataStr = parseStringOption(args, short: "-d", long: "--data") else {
            output.printError("missing --data value")
            return BlewExitCode.invalidArguments.code
        }
        let fmt = parseStringOption(args, short: "-F", long: "--format") ?? "hex"
        let withResponse = args.contains("-R") || args.contains("--with-response")
        let withoutResponse = args.contains("-W") || args.contains("--without-response")

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

        Task {
            do {
                try await manager.writeCharacteristic(charUUID, data: data, type: writeType)
                output.printInfo("written to \(charUUID)")
            } catch let error as BLEError {
                output.printError(error.localizedDescription)
                exitCode = error.exitCode
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
            semaphore.signal()
        }

        semaphore.wait()
        return exitCode
    }

    func runSub(_ args: [String]) -> Int32 {
        let connectCode = ensureConnected()
        guard connectCode == 0 else { return connectCode }

        guard let charInput = parseStringOption(args, short: "-c", long: "--char") else {
            output.printError("missing --char UUID")
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
        let fmt = parseStringOption(args, short: "-F", long: "--format") ?? "hex"
        let duration = parseDoubleOption(args, short: "-D", long: "--duration")
        let maxCount = parseIntOption(args, short: "-C", long: "--count")

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            do {
                let stream = try await manager.subscribe(characteristicUUID: charUUID)
                var count = 0
                let startTime = Date()

                for await data in stream {
                    let formatted = DataFormatter.format(data, as: fmt)
                    switch output.format {
                    case .text:
                        output.print(formatted)
                    case .kv:
                        let ts = ISO8601DateFormatter.shared.string(from: Date())
                        output.printRecord(("ts", ts), ("char", charUUID), ("value", formatted))
                    }

                    count += 1
                    if let maxCount = maxCount, count >= maxCount { break }
                    if let duration = duration, Date().timeIntervalSince(startTime) >= duration { break }
                }
            } catch let error as BLEError {
                output.printError(error.localizedDescription)
                exitCode = error.exitCode
            } catch {
                output.printError("\(error)")
                exitCode = BlewExitCode.operationFailed.code
            }
            semaphore.signal()
        }

        semaphore.wait()
        return exitCode
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

private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
