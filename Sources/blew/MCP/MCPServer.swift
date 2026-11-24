#if MCP_ENABLED
import Foundation
import MCP
import BLEManager

/// Collects what a streaming command emits during one tool call. A
/// command can keep emitting from a background task after the call has
/// returned (advertising events go on until `ble_periph_stop`); `close`
/// ends the collection and what arrives afterwards is dropped.
final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CommandOutput] = []
    private var isOpen = true

    func collect(_ item: CommandOutput) {
        lock.withLock {
            if isOpen { items.append(item) }
        }
    }

    /// Stop collecting and return what was collected.
    func close() -> [CommandOutput] {
        lock.withLock {
            isOpen = false
            defer { items = [] }
            return items
        }
    }
}

/// One validated tool call, ready to run on the router.
struct ToolCommand {
    /// The seconds the call itself asks for: a scan timeout, a subscription
    /// or NUS duration; zero for the other tools.
    var duration: TimeInterval
    var run: (CommandRouter) -> CommandResult
}

final class BlewMCPServer {
    /// The longest `duration` a `ble_subscribe` or `ble_nus` call, and the
    /// longest `timeout` a `ble_scan` call, may ask for.
    static let maxCallDuration: TimeInterval = 300
    /// How long `ble_subscribe` collects when the call gives no `duration`.
    static let defaultSubscribeDuration: TimeInterval = 10
    /// The time a call may take beyond its own duration, for connecting,
    /// discovery and the operation: this, or four times the global `-t`
    /// when that is longer.
    static let setupAllowance: TimeInterval = 60

    private let server: Server
    let router: CommandRouter
    private let calls = ToolCallQueue()
    /// The device switches of cancelled calls, which get no response.
    let unreportedSwitches = UnreportedDeviceSwitches()

    /// `globals` are the options given before `mcp` (`blew -t 30 mcp`).
    init(globals: GlobalOptions) {
        self.router = CommandRouter(
            globals: globals,
            isInteractiveMode: true,
            renderer: NullRenderer()
        )
        self.server = Server(
            name: "blew",
            version: Blew.version,
            instructions: """
                blew is a macOS BLE CLI workbench. Use these tools to scan for BLE devices, \
                connect to them, explore GATT services/characteristics, read/write values, \
                subscribe to notifications, and run a BLE peripheral (GATT server). \
                The server is stateful: connections persist across tool calls. \
                Tool calls never overlap: each starts after the one before it returned. \
                Send a call after the reply to the one it depends on.
                """,
            capabilities: .init(tools: .init())
        )
    }

    func start() async throws {
        await server
            .withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: Self.toolDefinitions)
            }
            .withMethodHandler(CallTool.self) { [self] params in
                try await handleToolCall(params)
            }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool call dispatch

    /// Validate a call's arguments, then run it on the tool-call queue
    /// within its budget. Throws `CancellationError` when the client
    /// cancelled the call, so the swift-sdk sends no response.
    func handleToolCall(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard let tool = Self.toolDefinitions.first(where: { $0.name == params.name }) else {
            throw MCPError.methodNotFound("Unknown tool: \(params.name)")
        }
        let args = params.arguments ?? [:]
        let command: ToolCommand
        do {
            try ToolArguments.validate(args, against: tool.inputSchema)
            command = try makeCommand(params.name, args)
        } catch let error as ToolArgumentError {
            return buildMCPResult(CommandResult(failing: InvalidArgument(error.message)))
        }
        return try await execute(command, name: params.name, budget: callBudget(command))
    }

    /// Run a validated call on the tool-call queue and turn its outcome into
    /// the call's result.
    func execute(_ command: ToolCommand, name: String, budget: TimeInterval) async throws -> CallTool.Result {
        let router = self.router
        let unreported = self.unreportedSwitches
        let outcome = await calls.run(budget: budget) { stop in
            router.collectingDeviceSwitches {
                router.run(stoppingOn: stop) { command.run(router) }
            }
        } settle: { ran, cancelled in
            // On the queue, before the next call runs, so the switches stay
            // in the order the calls ran however late each reply is built.
            let (result, own) = ran
            return (result: result, switches: unreported.settle(own: own, cancelled: cancelled))
        }
        var result: CommandResult
        let switches: [DeviceSwitch]
        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .finished(let finished):
            (result, switches) = finished
        case .budgetExhausted(let exhausted):
            (result, switches) = exhausted
            // A command that still succeeded is reported as it finished.
            if result.exitCode != 0 {
                result.exitCode = BlewExitCode.timeout.code
                result.errors.append("\(name) did not finish within its \(Int(budget))-second budget")
            }
        }
        return buildMCPResult(result, deviceSwitches: switches)
    }

    /// The seconds a call may run before it is stopped: its own duration
    /// plus the setup allowance.
    func callBudget(_ command: ToolCommand) -> TimeInterval {
        command.duration + max(Self.setupAllowance, 4 * (router.globals.timeout ?? 0))
    }

    /// The router work for a call to `name`, a tool of `toolDefinitions`,
    /// whose arguments passed validation.
    func makeCommand(_ name: String, _ args: [String: Value]) throws -> ToolCommand {
        func plain(_ run: @escaping (CommandRouter) -> CommandResult) -> ToolCommand {
            ToolCommand(duration: 0, run: run)
        }
        /// A streaming command: what it emits during the call comes first
        /// in the result.
        func streaming(duration: TimeInterval,
                       _ run: @escaping (CommandRouter, @escaping @Sendable (CommandOutput) -> Void) -> CommandResult)
            -> ToolCommand
        {
            ToolCommand(duration: duration) { router in
                let collector = StreamCollector()
                var result = run(router) { collector.collect($0) }
                result.output = collector.close() + result.output
                return result
            }
        }

        switch name {
        case "ble_scan":
            let scanArgs = buildScanArgs(args)
            return ToolCommand(duration: number(args["timeout"]) ?? 0) { $0.runScan(scanArgs) }
        case "ble_connect":
            let connectArgs = buildConnectArgs(args)
            return plain { $0.runConnect(connectArgs) }
        case "ble_disconnect":
            return plain { $0.runDisconnect([]) }
        case "ble_status":
            return plain { $0.runStatus([]) }
        case "ble_gatt_services":
            let gattArgs = buildGATTArgs("svcs", args)
            return plain { $0.runGATT(gattArgs) }
        case "ble_gatt_tree":
            let gattArgs = buildGATTArgs("tree", args)
            return plain { $0.runGATT(gattArgs) }
        case "ble_gatt_chars":
            let gattArgs = buildGATTArgs("chars", args)
            return plain { $0.runGATT(gattArgs) }
        case "ble_gatt_descriptors":
            let gattArgs = buildGATTArgs("desc", args)
            return plain { $0.runGATT(gattArgs) }
        case "ble_gatt_info":
            let gattArgs = buildGATTArgs("info", args)
            return plain { $0.runGATT(gattArgs) }
        case "ble_read":
            let readArgs = buildReadArgs(args)
            return plain { $0.runRead(readArgs) }
        case "ble_write":
            let writeArgs = buildWriteArgs(args)
            return plain { $0.runWrite(writeArgs) }
        case "ble_subscribe":
            let subArgs = buildSubArgs(args)
            let duration = number(args["duration"]) ?? Self.defaultSubscribeDuration
            return streaming(duration: duration) { $0.runSub(subArgs, foregroundOnly: true, emit: $1) }
        case "ble_periph_advertise":
            let periphArgs = buildPeriphAdvArgs(args)
            return streaming(duration: 0) { $0.runPeriph(periphArgs, emit: $1) }
        case "ble_periph_clone":
            let periphArgs = buildPeriphCloneArgs(args)
            return streaming(duration: 0) { $0.runPeriph(periphArgs, emit: $1) }
        case "ble_periph_stop":
            return plain { $0.runPeriph(["stop"]) }
        case "ble_periph_set":
            let periphArgs = buildPeriphSetArgs("set", args)
            return plain { $0.runPeriph(periphArgs) }
        case "ble_periph_notify":
            let periphArgs = buildPeriphSetArgs("notify", args)
            return plain { $0.runPeriph(periphArgs) }
        case "ble_periph_status":
            return plain { $0.runPeriph(["status"]) }
        case "ble_nus":
            let options: NUSOptions
            do {
                options = try buildNUSOptions(args)
            } catch {
                throw ToolArgumentError(message: "\(error)")
            }
            return streaming(duration: options.linger) { $0.runNUS(options, emit: $1) }
        default:
            preconditionFailure("tool \(name) has a definition but no command")
        }
    }

    /// A validated `number` argument, in seconds.
    func number(_ value: Value?) -> TimeInterval? {
        value?.doubleValue ?? value?.intValue.map(Double.init)
    }

    // MARK: - Result conversion

    private static let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    /// The call's result. `deviceSwitches` are the connected devices the
    /// call replaced, in order; when there are any, they are the
    /// `deviceSwitches` field of the structured result, beside the command's
    /// own fields.
    func buildMCPResult(_ result: CommandResult, deviceSwitches: [DeviceSwitch] = []) -> CallTool.Result {
        var structured = encodeStructuredContent(result.output).flatMap { try? Value($0) }
        if !deviceSwitches.isEmpty, let value = try? Value(deviceSwitches) {
            var fields = structured?.objectValue ?? [:]
            fields["deviceSwitches"] = value
            structured = .object(fields)
        }
        return CallTool.Result(
            content: [.text(text: buildTextContent(result, structured: structured), annotations: nil, _meta: nil)],
            structuredContent: structured,
            isError: result.exitCode != 0
        )
    }

    func encodeStructuredContent(_ output: [CommandOutput]) -> StructuredResult? {
        guard !output.isEmpty else { return nil }

        for item in output {
            switch item {
            case .devices(let rows):
                return .devices(rows)
            case .services(let rows):
                return .services(rows)
            case .characteristics(let rows):
                return .characteristics(rows)
            case .descriptors(let rows):
                return .descriptors(rows)
            case .gattTree(let tree):
                return .gattTree(tree)
            case .characteristicInfo(let info):
                return .characteristicInfo(info)
            case .connectionStatus(let status):
                return .connectionStatus(status)
            case .peripheralStatus(let status):
                return .peripheralStatus(status)
            case .readValue(let rv):
                return .readValue(rv)
            case .writeSuccess(let char, let name):
                return .writeSuccess(WriteSuccessResult(char: char, name: name))
            case .notification, .notificationsDropped:
                let allNotifications = output.compactMap { item -> NotificationValue? in
                    if case .notification(let n) = item { return n }
                    return nil
                }
                // Each report carries the total so far; the last is the total.
                let dropped = output.reduce(0) { total, item in
                    if case .notificationsDropped(let drops) = item { return drops.total }
                    return total
                }
                return .notifications(allNotifications, dropped: dropped)
            case .peripheralSummary(let summary):
                return .peripheralSummary(summary)
            case .peripheralEvent:
                let allEvents = output.compactMap { item -> PeriphEventRecord? in
                    if case .peripheralEvent(let r) = item { return r }
                    return nil
                }
                return .peripheralEvents(allEvents)
            case .subscriptionList(let uuids):
                return .subscriptionList(uuids)
            case .nusData, .nusStatus, .nusDropped:
                let bytes = output.reduce(into: Data()) { all, item in
                    if case .nusData(let record) = item { all.append(record.data) }
                }
                // Each report carries the command's total so far; the last is the total.
                let dropped = output.reduce(0) { total, item in
                    if case .nusDropped(let drops) = item { return drops.total }
                    return total
                }
                return .nus(NUSTranscript(received: String(decoding: bytes, as: UTF8.self),
                                          receivedHex: DataFormatter.format(bytes, as: .hex),
                                          dropped: dropped))
            case .message(let msg):
                return .message(msg)
            case .empty:
                continue
            }
        }
        return nil
    }

    /// Build the text content for the MCP result. When structured data is
    /// available, serialize it as JSON so agents that only read `content`
    /// still get the full data instead of a useless summary.
    func buildTextContent(_ result: CommandResult, structured: Value?) -> String {
        var parts: [String] = []

        for msg in result.errors {
            parts.append("Error: \(msg)")
        }

        if let structured = structured,
           let data = try? Self.jsonEncoder.encode(structured),
           let json = String(data: data, encoding: .utf8) {
            parts.append(json)
        }

        if parts.isEmpty {
            for msg in result.infos {
                parts.append(msg)
            }
        }

        return parts.isEmpty ? "OK" : parts.joined(separator: "\n")
    }

    func peripheralEventText(_ event: PeripheralEvent) -> String {
        switch event {
        case .stateChanged:            return "state changed"
        case .advertisingStarted:      return "advertising started"
        case .serviceAdded:            return "service added"
        case .centralConnected(let id):     return "central \(String(id.prefix(8))) connected"
        case .centralDisconnected(let id):  return "central \(String(id.prefix(8))) disconnected"
        case .readRequest(let id, let uuid):     return "read \(uuid) by \(String(id.prefix(8)))"
        case .writeRequest(let id, let uuid, _): return "write \(uuid) by \(String(id.prefix(8)))"
        case .subscribed(let id, let uuid):      return "subscribe \(uuid) by \(String(id.prefix(8)))"
        case .unsubscribed(let id, let uuid):    return "unsubscribe \(uuid) by \(String(id.prefix(8)))"
        case .notificationSent(let uuid, let n): return "notification on \(uuid) to \(n) subscriber(s)"
        }
    }

    // MARK: - Argument builders

    func buildTargetingArgs(_ args: [String: Value]) -> [String] {
        var result: [String] = []
        if let name = args["name"]?.stringValue { result += ["-n", name] }
        if let id = args["device_id"]?.stringValue { result += ["-i", id] }
        if let svc = args["service"]?.stringValue { result += ["-S", svc] }
        if let mfr = args["manufacturer"]?.intValue { result += ["-m", "\(mfr)"] }
        if let rssi = args["rssi_min"]?.intValue { result += ["-R", "\(rssi)"] }
        if let pick = args["pick"]?.stringValue { result += ["-p", pick] }
        return result
    }

    func buildScanArgs(_ args: [String: Value]) -> [String] {
        var result = buildTargetingArgs(args)
        if let timeout = number(args["timeout"]) {
            result += ["-t", "\(timeout)"]
        }
        return result
    }

    /// `device_id` names the device as `-i`, so connect takes no positional.
    func buildConnectArgs(_ args: [String: Value]) -> [String] {
        buildTargetingArgs(args)
    }

    /// The positional values of a command line, after `--`, so a value that
    /// starts with `-` (write data, a UUID typed wrong) stays a value and is
    /// checked as one, never read as an option. Absent fields are left out.
    func positionals(_ values: String?...) -> [String] {
        [CommandSyntax.endOfOptions] + values.compactMap { $0 }
    }

    /// The `gatt <sub>` command line of a `ble_gatt_*` call. Each tool's
    /// schema admits only its own fields, so the fields it does not take
    /// are absent here.
    func buildGATTArgs(_ sub: String, _ args: [String: Value]) -> [String] {
        var result = [sub] + buildTargetingArgs(args)
        if args["descriptors"]?.boolValue == true { result.append("--descriptors") }
        if args["read_values"]?.boolValue == true { result.append("--read") }
        if let fmt = args["format"]?.stringValue { result += ["-f", fmt] }
        return result + positionals(args["service_uuid"]?.stringValue, args["char_uuid"]?.stringValue)
    }

    func buildReadArgs(_ args: [String: Value]) -> [String] {
        var result = buildTargetingArgs(args)
        if let fmt = args["format"]?.stringValue { result += ["-f", fmt] }
        return result + positionals(args["char_uuid"]?.stringValue)
    }

    func buildWriteArgs(_ args: [String: Value]) -> [String] {
        var result = buildTargetingArgs(args)
        if let fmt = args["format"]?.stringValue { result += ["-f", fmt] }
        if args["with_response"]?.boolValue == true { result.append("-r") }
        if args["with_response"]?.boolValue == false { result.append("-w") }
        return result + positionals(args["char_uuid"]?.stringValue, args["data"]?.stringValue)
    }

    func buildSubArgs(_ args: [String: Value]) -> [String] {
        var result = buildTargetingArgs(args)
        if let fmt = args["format"]?.stringValue { result += ["-f", fmt] }
        let duration = number(args["duration"]) ?? Self.defaultSubscribeDuration
        result += ["-d", "\(duration)"]
        if let count = args["count"]?.intValue { result += ["-c", "\(count)"] }
        return result + positionals(args["char_uuid"]?.stringValue)
    }

    /// The options of a `ble_nus` call, built from typed fields: free text
    /// goes only where its field says, never through a command line.
    func buildNUSOptions(_ args: [String: Value]) throws -> NUSOptions {
        let withResponse = args["with_response"]?.boolValue
        return try NUSOptions.make(
            targeting: DeviceTarget(CommandSyntax.targeting.parse(buildTargetingArgs(args))),
            sends: args["send"]?.stringValue.map { [$0] } ?? [],
            expect: args["expect"]?.stringValue,
            duration: number(args["duration"]),
            withResponse: withResponse == true,
            withoutResponse: withResponse == false,
            stdinAvailable: false)
    }

    func buildPeriphAdvArgs(_ args: [String: Value]) -> [String] {
        var result = ["adv"]
        if let name = args["name"]?.stringValue { result += ["-n", name] }
        if let svcs = args["services"]?.arrayValue {
            for svc in svcs {
                if let s = svc.stringValue { result += ["-S", s] }
            }
        }
        if let cfg = args["config_file"]?.stringValue { result += ["-c", cfg] }
        return result
    }

    func buildPeriphCloneArgs(_ args: [String: Value]) -> [String] {
        var result = ["clone"] + buildTargetingArgs(args)
        if let file = args["save_file"]?.stringValue { result += [OptionSpec.save.long, file] }
        return result
    }

    func buildPeriphSetArgs(_ cmd: String, _ args: [String: Value]) -> [String] {
        var result = [cmd]
        if let fmt = args["format"]?.stringValue { result += ["-f", fmt] }
        return result + positionals(args["char_uuid"]?.stringValue, args["value"]?.stringValue)
    }
}

/// The device switches of cancelled MCP calls, which get no response, in
/// the order the calls ran. Every call that ran passes its own switches
/// through `settle`, on the tool-call queue, so the order is the queue's.
/// It holds switches only: a cancelled call that switched nothing adds
/// nothing, and each entry is a real disconnect and connect. The lock lets
/// a test read it from another thread.
final class UnreportedDeviceSwitches: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [DeviceSwitch] = []

    /// The switches a call reports, given its own, `own`: none for a
    /// cancelled call, whose switches wait for the next call that finishes;
    /// for a call that finished, every waiting switch and then its own, so
    /// the last `to` is the device connected now.
    func settle(own: [DeviceSwitch], cancelled: Bool) -> [DeviceSwitch] {
        lock.withLock {
            waiting += own
            guard !cancelled else { return [] }
            defer { waiting = [] }
            return waiting
        }
    }

    var isEmpty: Bool { lock.withLock { waiting.isEmpty } }
}

// MARK: - Structured result wrapper

enum StructuredResult: Codable {
    case devices([DeviceRow])
    case services([ServiceRow])
    case characteristics([CharacteristicRow])
    case descriptors([DescriptorRow])
    case gattTree([GATTTreeService])
    case characteristicInfo(GATTCharInfo)
    case connectionStatus(ConnectionStatus)
    case peripheralStatus(PeripheralStatus)
    case readValue(ReadResult)
    case writeSuccess(WriteSuccessResult)
    /// The values a subscription received, and how many it dropped because
    /// they came faster than it collected them.
    case notifications([NotificationValue], dropped: Int = 0)
    case peripheralSummary(PeriphSummaryResult)
    case peripheralEvents([PeriphEventRecord])
    case subscriptionList([String])
    case message(String)
    case nus(NUSTranscript)

    private enum CodingKeys: String, CodingKey {
        case type
        case devices, services, characteristics, descriptors, tree
        case characteristicInfo, connectionStatus, peripheralStatus
        case readValue, writeSuccess, notifications, dropped
        case peripheralSummary, peripheralEvents
        case subscriptions, message, nus
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .devices(let rows):
            try container.encode("devices", forKey: .type)
            try container.encode(rows, forKey: .devices)
        case .services(let rows):
            try container.encode("services", forKey: .type)
            try container.encode(rows, forKey: .services)
        case .characteristics(let rows):
            try container.encode("characteristics", forKey: .type)
            try container.encode(rows, forKey: .characteristics)
        case .descriptors(let rows):
            try container.encode("descriptors", forKey: .type)
            try container.encode(rows, forKey: .descriptors)
        case .gattTree(let tree):
            try container.encode("gattTree", forKey: .type)
            try container.encode(tree, forKey: .tree)
        case .characteristicInfo(let info):
            try container.encode("characteristicInfo", forKey: .type)
            try container.encode(info, forKey: .characteristicInfo)
        case .connectionStatus(let status):
            try container.encode("connectionStatus", forKey: .type)
            try container.encode(status, forKey: .connectionStatus)
        case .peripheralStatus(let status):
            try container.encode("peripheralStatus", forKey: .type)
            try container.encode(status, forKey: .peripheralStatus)
        case .readValue(let rv):
            try container.encode("readValue", forKey: .type)
            try container.encode(rv, forKey: .readValue)
        case .writeSuccess(let ws):
            try container.encode("writeSuccess", forKey: .type)
            try container.encode(ws, forKey: .writeSuccess)
        case .notifications(let nvs, let dropped):
            try container.encode("notifications", forKey: .type)
            try container.encode(nvs, forKey: .notifications)
            try container.encode(dropped, forKey: .dropped)
        case .peripheralSummary(let summary):
            try container.encode("peripheralSummary", forKey: .type)
            try container.encode(summary, forKey: .peripheralSummary)
        case .peripheralEvents(let events):
            try container.encode("peripheralEvents", forKey: .type)
            try container.encode(events, forKey: .peripheralEvents)
        case .subscriptionList(let uuids):
            try container.encode("subscriptionList", forKey: .type)
            try container.encode(uuids, forKey: .subscriptions)
        case .message(let msg):
            try container.encode("message", forKey: .type)
            try container.encode(msg, forKey: .message)
        case .nus(let transcript):
            try container.encode("nus", forKey: .type)
            try container.encode(transcript, forKey: .nus)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "devices":          self = .devices(try container.decode([DeviceRow].self, forKey: .devices))
        case "services":         self = .services(try container.decode([ServiceRow].self, forKey: .services))
        case "characteristics":  self = .characteristics(try container.decode([CharacteristicRow].self, forKey: .characteristics))
        case "descriptors":      self = .descriptors(try container.decode([DescriptorRow].self, forKey: .descriptors))
        case "gattTree":         self = .gattTree(try container.decode([GATTTreeService].self, forKey: .tree))
        case "characteristicInfo": self = .characteristicInfo(try container.decode(GATTCharInfo.self, forKey: .characteristicInfo))
        case "connectionStatus": self = .connectionStatus(try container.decode(ConnectionStatus.self, forKey: .connectionStatus))
        case "peripheralStatus": self = .peripheralStatus(try container.decode(PeripheralStatus.self, forKey: .peripheralStatus))
        case "readValue":        self = .readValue(try container.decode(ReadResult.self, forKey: .readValue))
        case "writeSuccess":     self = .writeSuccess(try container.decode(WriteSuccessResult.self, forKey: .writeSuccess))
        case "notifications":    self = .notifications(try container.decode([NotificationValue].self, forKey: .notifications),
                                                       dropped: try container.decodeIfPresent(Int.self, forKey: .dropped) ?? 0)
        case "peripheralSummary": self = .peripheralSummary(try container.decode(PeriphSummaryResult.self, forKey: .peripheralSummary))
        case "peripheralEvents": self = .peripheralEvents(try container.decode([PeriphEventRecord].self, forKey: .peripheralEvents))
        case "subscriptionList": self = .subscriptionList(try container.decode([String].self, forKey: .subscriptions))
        case "message":          self = .message(try container.decode(String.self, forKey: .message))
        case "nus":              self = .nus(try container.decode(NUSTranscript.self, forKey: .nus))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                debugDescription: "Unknown StructuredResult type: \(type)")
        }
    }
}

struct WriteSuccessResult: Codable {
    let char: String
    let name: String?
}

// MARK: - Tool definitions

extension BlewMCPServer {
    static let toolDefinitions: [Tool] = [
        Tool(
            name: "ble_scan",
            description: "Scan for nearby BLE devices. Returns a list of discovered devices with their IDs, names, RSSI, manufacturer (company identifier and name), and advertised services.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name":         .object(["type": .string("string"), "description": .string("Filter by device name (substring match)")]),
                    "service":      .object(["type": .string("string"), "description": .string("Filter by advertised service UUID")]),
                    "rssi_min":     .object(["type": .string("integer"), "description": .string("Minimum RSSI threshold (e.g. -70)")]),
                    "manufacturer": manufacturerProperty,
                    "pick":         .object(["type": .string("string"), "enum": .array([.string("strongest"), .string("first"), .string("only")]), "description": .string("Return only the device this strategy picks: strongest RSSI, first discovered, or the only match (error when several match)")]),
                    "timeout":      .object(["type": .string("number"), "minimum": .int(0), "maximum": .double(maxCallDuration), "description": .string("Scan duration in seconds (default: 5, at most \(Int(maxCallDuration)))")]),
                ]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)
        ),
        Tool(
            name: "ble_connect",
            description: "Connect to a BLE device by ID, name, or other filters. The connection persists across subsequent tool calls.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "device_id":    .object(["type": .string("string"), "description": .string("Identifier (UUID) of the device to connect to, or a fragment of it that matches one device; never a name")]),
                    "name":         .object(["type": .string("string"), "description": .string("Connect to device matching this name (substring)")]),
                    "service":      .object(["type": .string("string"), "description": .string("Filter by advertised service UUID")]),
                    "manufacturer": manufacturerProperty,
                    "rssi_min":     .object(["type": .string("integer"), "description": .string("Minimum RSSI threshold")]),
                    "pick":         .object(["type": .string("string"), "enum": .array([.string("strongest"), .string("first"), .string("only")]), "description": .string("Auto-select strategy")]),
                ]),
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
        ),
        Tool(
            name: "ble_disconnect",
            description: "Disconnect from the currently connected BLE device.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "ble_status",
            description: "Show the current BLE connection status: connected device, service/characteristic counts, active subscriptions.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "ble_gatt_services",
            description: "List GATT services on the connected device (or auto-connect using targeting options).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetingProperties),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)
        ),
        Tool(
            name: "ble_gatt_tree",
            description: "Show the full GATT tree: services, characteristics, and optionally descriptors and read values.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetingProperties.merging([
                    "descriptors":  .object(["type": .string("boolean"), "description": .string("Include descriptors in the tree")]),
                    "read_values":  .object(["type": .string("boolean"), "description": .string("Read and include characteristic values")]),
                    "format":       .object(["type": .string("string"), "enum": listingFormatNames, "description": .string("Show every read value in this format instead of decoding it (needs read_values)")]),
                ]) { $1 }),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)
        ),
        Tool(
            name: "ble_gatt_chars",
            description: "List characteristics of a specific GATT service.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetingProperties.merging([
                    "service_uuid": .object(["type": .string("string"), "description": .string("Service UUID to list characteristics for")]),
                    "read_values":  .object(["type": .string("boolean"), "description": .string("Read and include characteristic values")]),
                    "format":       .object(["type": .string("string"), "enum": listingFormatNames, "description": .string("Show every read value in this format instead of decoding it (needs read_values)")]),
                ]) { $1 }),
                "required": .array([.string("service_uuid")]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)
        ),
        Tool(
            name: "ble_gatt_descriptors",
            description: "List descriptors of a specific GATT characteristic.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetingProperties.merging([
                    "char_uuid": .object(["type": .string("string"), "description": .string("Characteristic UUID")]),
                ]) { $1 }),
                "required": .array([.string("char_uuid")]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)
        ),
        Tool(
            name: "ble_gatt_info",
            description: "Look up Bluetooth SIG specification info for a characteristic UUID: name, description, field structure. Does not require a connected device.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "char_uuid": .object(["type": .string("string"), "description": .string("Characteristic UUID to look up")]),
                ]),
                "required": .array([.string("char_uuid")]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "ble_read",
            description: "Read the value of a GATT characteristic. Auto-connects if not already connected.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetingProperties.merging([
                    "char_uuid": .object(["type": .string("string"), "description": .string("Characteristic UUID to read")]),
                    "format":    .object(["type": .string("string"), "enum": formatNames, "description": .string("Output format (default: hex)")]),
                ]) { $1 }),
                "required": .array([.string("char_uuid")]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)
        ),
        Tool(
            name: "ble_write",
            description: "Write a value to a GATT characteristic. Auto-connects if not already connected.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetingProperties.merging([
                    "char_uuid":     .object(["type": .string("string"), "description": .string("Characteristic UUID to write")]),
                    "data":          .object(["type": .string("string"), "description": .string("Value to write (interpreted according to format)")]),
                    "format":        .object(["type": .string("string"), "enum": formatNames, "description": .string("Input format (default: hex)")]),
                    "with_response": .object(["type": .string("boolean"), "description": .string("true = write with response, false = without response, omit = auto")]),
                ]) { $1 }),
                "required": .array([.string("char_uuid"), .string("data")]),
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
        ),
        Tool(
            name: "ble_subscribe",
            description: "Subscribe to notifications on a GATT characteristic. Collects notifications for `duration` seconds (default \(Int(defaultSubscribeDuration)), at most \(Int(maxCallDuration))), or until `count` have arrived when that comes first, then returns all values at once.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetingProperties.merging([
                    "char_uuid": .object(["type": .string("string"), "description": .string("Characteristic UUID to subscribe to")]),
                    "format":    .object(["type": .string("string"), "enum": formatNames, "description": .string("Value format (default: hex)")]),
                    "duration":  .object(["type": .string("number"), "minimum": .int(0), "maximum": .double(maxCallDuration), "description": .string("Collection duration in seconds (default: \(Int(defaultSubscribeDuration)), at most \(Int(maxCallDuration)))")]),
                    "count":     .object(["type": .string("integer"), "minimum": .int(1), "description": .string("Stop after this many notifications (default: no limit; the call still ends after `duration`)")]),
                ]) { $1 }),
                "required": .array([.string("char_uuid")]),
            ]),
            annotations: .init(readOnlyHint: true, openWorldHint: true)
        ),
        Tool(
            name: "ble_periph_advertise",
            description: "Start advertising as a BLE peripheral (GATT server). Configures the GATT database and begins advertising. The peripheral persists across tool calls; use ble_periph_stop to stop.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name":        .object(["type": .string("string"), "description": .string("Advertised device name")]),
                    "services":    .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Service UUIDs to advertise")]),
                    "config_file": .object(["type": .string("string"), "description": .string("Path to GATT config JSON file")]),
                ]),
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
        ),
        Tool(
            name: "ble_periph_clone",
            description: "Clone a real BLE device's GATT structure and advertise as a peripheral replica.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetingProperties.merging([
                    "save_file": .object(["type": .string("string"), "description": .string("Save cloned config to this JSON file")]),
                ]) { $1 }),
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
        ),
        Tool(
            name: "ble_periph_stop",
            description: "Stop advertising and shut down the BLE peripheral.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "ble_periph_set",
            description: "Update a characteristic value in the peripheral's GATT store.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "char_uuid": .object(["type": .string("string"), "description": .string("Characteristic UUID")]),
                    "value":     .object(["type": .string("string"), "description": .string("New value")]),
                    "format":    .object(["type": .string("string"), "enum": formatNames, "description": .string("Value format (default: hex)")]),
                ]),
                "required": .array([.string("char_uuid"), .string("value")]),
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "ble_periph_notify",
            description: "Update a characteristic value and push a notification to subscribed centrals.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "char_uuid": .object(["type": .string("string"), "description": .string("Characteristic UUID")]),
                    "value":     .object(["type": .string("string"), "description": .string("Value to send")]),
                    "format":    .object(["type": .string("string"), "enum": formatNames, "description": .string("Value format (default: hex)")]),
                ]),
                "required": .array([.string("char_uuid"), .string("value")]),
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
        ),
        Tool(
            name: "ble_periph_status",
            description: "Show the current peripheral advertising state.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            annotations: .init(readOnlyHint: true, openWorldHint: false)
        ),
        Tool(
            name: "ble_nus",
            description: "Talk to a device's Nordic UART Service (NUS). Connects (by default to the strongest device advertising NUS), subscribes to TX, writes `send` to RX in MTU-sized chunks, and collects what the device sends back until `expect` arrives or `duration` seconds pass after sending. Returns the received bytes as text and hex; with `expect`, the call fails if the text does not arrive.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetingProperties.merging([
                    "send":          .object(["type": .string("string"), "description": .string("Text to send; printf-style escapes \\n \\r \\t \\0 \\\\ \\xHH are decoded. No newline is added.")]),
                    "expect":        .object(["type": .string("string"), "description": .string("Text to wait for (same escapes); the call succeeds once it arrives")]),
                    "duration":      .object(["type": .string("number"), "minimum": .int(0), "maximum": .double(maxCallDuration), "description": .string("Seconds to listen after sending (default 1); with expect, the deadline for it (default 5); at most \(Int(maxCallDuration))")]),
                    "with_response": .object(["type": .string("boolean"), "description": .string("true = write with response, false = without response, omit = auto")]),
                ]) { $1 }),
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
        ),
    ]

    /// The `manufacturer` filter: a JSON integer, which `buildTargetingArgs`
    /// passes to `-m` in decimal.
    static let manufacturerProperty: Value = .object([
        "type": .string("integer"), "minimum": .int(0), "maximum": .int(65535),
        "description": .string("Filter by the Bluetooth SIG company identifier that starts the manufacturer data, as an integer (76 is 0x004C, Apple)"),
    ])

    /// The `format` values a tool takes: every `ValueFormat`, in its order.
    static let formatNames: Value = .array(ValueFormat.allCases.map { .string($0.rawValue) })
    /// The `format` values `ble_gatt_tree` and `ble_gatt_chars` take: every
    /// `ValueFormat.listingFormats`.
    static let listingFormatNames: Value = .array(ValueFormat.listingFormats.map { .string($0.rawValue) })

    static let targetingProperties: [String: Value] = [
        "name":         .object(["type": .string("string"), "description": .string("Device name filter (substring match)")]),
        "device_id":    .object(["type": .string("string"), "description": .string("Device identifier (UUID), or a fragment of it that matches one device; never a name")]),
        "service":      .object(["type": .string("string"), "description": .string("Service UUID filter")]),
        "manufacturer": manufacturerProperty,
        "rssi_min":     .object(["type": .string("integer"), "description": .string("Minimum RSSI threshold")]),
        "pick":         .object(["type": .string("string"), "enum": .array([.string("strongest"), .string("first"), .string("only")]), "description": .string("Auto-select strategy")]),
    ]
}
#endif
