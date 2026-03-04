import Foundation
import MCP
import BLEManager

/// Reference-type accumulator for streaming command output.
/// @unchecked Sendable is safe here: run*() methods are synchronous (semaphore-blocked)
/// so all emit() calls complete before the collected items are read.
private final class StreamCollector: @unchecked Sendable {
    var items: [CommandOutput] = []
    func collect(_ item: CommandOutput) { items.append(item) }
}

final class BlewMCPServer {
    private let server: Server
    private let router: CommandRouter

    init() {
        let globals = try! GlobalOptions.parse([])
        self.router = CommandRouter(
            globals: globals,
            isInteractiveMode: true,
            renderer: NullRenderer()
        )
        self.server = Server(
            name: "blew",
            version: "0.1.0",
            instructions: """
                blew is a macOS BLE CLI workbench. Use these tools to scan for BLE devices, \
                connect to them, explore GATT services/characteristics, read/write values, \
                subscribe to notifications, and run a BLE peripheral (GATT server). \
                The server is stateful: connections persist across tool calls.
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

    func handleToolCall(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let args = params.arguments ?? [:]

        let result: CommandResult
        switch params.name {
        case "ble_scan":
            result = router.runScan(buildScanArgs(args))
        case "ble_connect":
            result = router.runConnect(buildConnectArgs(args))
        case "ble_disconnect":
            result = router.runDisconnect([])
        case "ble_status":
            result = router.runStatus([])
        case "ble_gatt_services":
            result = router.runGATT(["svcs"] + buildTargetingArgs(args))
        case "ble_gatt_tree":
            var gattArgs = ["tree"] + buildTargetingArgs(args)
            if args["descriptors"]?.boolValue == true { gattArgs.append("--descriptors") }
            if args["read_values"]?.boolValue == true { gattArgs.append("--read") }
            result = router.runGATT(gattArgs)
        case "ble_gatt_chars":
            var gattArgs = ["chars"] + buildTargetingArgs(args)
            if let svc = args["service_uuid"]?.stringValue { gattArgs.append(svc) }
            if args["read_values"]?.boolValue == true { gattArgs.append("--read") }
            result = router.runGATT(gattArgs)
        case "ble_gatt_descriptors":
            var gattArgs = ["desc"] + buildTargetingArgs(args)
            if let char = args["char_uuid"]?.stringValue { gattArgs.append(char) }
            result = router.runGATT(gattArgs)
        case "ble_gatt_info":
            var gattArgs = ["info"]
            if let char = args["char_uuid"]?.stringValue { gattArgs.append(char) }
            result = router.runGATT(gattArgs)
        case "ble_read":
            result = router.runRead(buildReadArgs(args))
        case "ble_write":
            result = router.runWrite(buildWriteArgs(args))
        case "ble_subscribe":
            let collector = StreamCollector()
            var r = router.runSub(buildSubArgs(args), emit: { collector.collect($0) })
            r.output = collector.items + r.output
            result = r
        case "ble_periph_advertise":
            let collector = StreamCollector()
            var r = router.runPeriph(buildPeriphAdvArgs(args), emit: { collector.collect($0) })
            r.output = collector.items + r.output
            result = r
        case "ble_periph_clone":
            let collector = StreamCollector()
            var r = router.runPeriph(buildPeriphCloneArgs(args), emit: { collector.collect($0) })
            r.output = collector.items + r.output
            result = r
        case "ble_periph_stop":
            result = router.runPeriph(["stop"])
        case "ble_periph_set":
            result = router.runPeriph(buildPeriphSetArgs("set", args))
        case "ble_periph_notify":
            result = router.runPeriph(buildPeriphSetArgs("notify", args))
        case "ble_periph_status":
            result = router.runPeriph(["status"])
        default:
            throw MCPError.methodNotFound("Unknown tool: \(params.name)")
        }

        return buildMCPResult(result)
    }

    // MARK: - Result conversion

    private static let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    func buildMCPResult(_ result: CommandResult) -> CallTool.Result {
        let isError = result.exitCode != 0
        let structured = encodeStructuredContent(result.output)
        let text = buildTextContent(result, structured: structured)

        do {
            if let structured = structured {
                return try CallTool.Result(
                    content: [.text(text)],
                    structuredContent: structured,
                    isError: isError
                )
            }
        } catch {
            // Fall through to text-only
        }

        return CallTool.Result(
            content: [.text(text)],
            isError: isError
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
            case .notification(let nv):
                if output.count == 1 {
                    return .notifications([nv])
                }
                let allNotifications = output.compactMap { item -> NotificationValue? in
                    if case .notification(let n) = item { return n }
                    return nil
                }
                return .notifications(allNotifications)
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
    func buildTextContent(_ result: CommandResult, structured: StructuredResult?) -> String {
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
        if let timeout = args["timeout"]?.doubleValue ?? args["timeout"]?.intValue.map(Double.init) {
            result += ["-t", "\(timeout)"]
        }
        return result
    }

    func buildConnectArgs(_ args: [String: Value]) -> [String] {
        var result = buildTargetingArgs(args)
        if let id = args["device_id"]?.stringValue, !result.contains("-i") {
            result.append(id)
        }
        return result
    }

    func buildReadArgs(_ args: [String: Value]) -> [String] {
        var result = buildTargetingArgs(args)
        if let fmt = args["format"]?.stringValue { result += ["-f", fmt] }
        if let char = args["char_uuid"]?.stringValue { result.append(char) }
        return result
    }

    func buildWriteArgs(_ args: [String: Value]) -> [String] {
        var result = buildTargetingArgs(args)
        if let fmt = args["format"]?.stringValue { result += ["-f", fmt] }
        if args["with_response"]?.boolValue == true { result.append("-r") }
        if args["with_response"]?.boolValue == false { result.append("-w") }
        if let char = args["char_uuid"]?.stringValue { result.append(char) }
        if let data = args["data"]?.stringValue { result.append(data) }
        return result
    }

    func buildSubArgs(_ args: [String: Value]) -> [String] {
        var result = buildTargetingArgs(args)
        if let fmt = args["format"]?.stringValue { result += ["-f", fmt] }
        if let dur = args["duration"]?.doubleValue ?? args["duration"]?.intValue.map(Double.init) {
            result += ["-d", "\(dur)"]
        }
        let count = args["count"]?.intValue
        if let count = count { result += ["-c", "\(count)"] }
        if count == nil && args["duration"] == nil {
            result += ["-c", "10"]
        }
        if let char = args["char_uuid"]?.stringValue { result.append(char) }
        return result
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
        if let file = args["save_file"]?.stringValue { result += ["-o", file] }
        return result
    }

    func buildPeriphSetArgs(_ cmd: String, _ args: [String: Value]) -> [String] {
        var result = [cmd]
        if let fmt = args["format"]?.stringValue { result += ["-f", fmt] }
        if let char = args["char_uuid"]?.stringValue { result.append(char) }
        if let value = args["value"]?.stringValue { result.append(value) }
        return result
    }
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
    case notifications([NotificationValue])
    case peripheralSummary(PeriphSummaryResult)
    case peripheralEvents([PeriphEventRecord])
    case subscriptionList([String])
    case message(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case devices, services, characteristics, descriptors, tree
        case characteristicInfo, connectionStatus, peripheralStatus
        case readValue, writeSuccess, notifications
        case peripheralSummary, peripheralEvents
        case subscriptions, message
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
        case .notifications(let nvs):
            try container.encode("notifications", forKey: .type)
            try container.encode(nvs, forKey: .notifications)
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
        case "notifications":    self = .notifications(try container.decode([NotificationValue].self, forKey: .notifications))
        case "peripheralSummary": self = .peripheralSummary(try container.decode(PeriphSummaryResult.self, forKey: .peripheralSummary))
        case "peripheralEvents": self = .peripheralEvents(try container.decode([PeriphEventRecord].self, forKey: .peripheralEvents))
        case "subscriptionList": self = .subscriptionList(try container.decode([String].self, forKey: .subscriptions))
        case "message":          self = .message(try container.decode(String.self, forKey: .message))
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
            description: "Scan for nearby BLE devices. Returns a list of discovered devices with their IDs, names, RSSI, and advertised services.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name":         .object(["type": .string("string"), "description": .string("Filter by device name (substring match)")]),
                    "service":      .object(["type": .string("string"), "description": .string("Filter by advertised service UUID")]),
                    "rssi_min":     .object(["type": .string("integer"), "description": .string("Minimum RSSI threshold (e.g. -70)")]),
                    "manufacturer": .object(["type": .string("integer"), "description": .string("Filter by manufacturer ID")]),
                    "pick":         .object(["type": .string("string"), "enum": .array([.string("strongest"), .string("first"), .string("only")]), "description": .string("Auto-select strategy when multiple devices match")]),
                    "timeout":      .object(["type": .string("number"), "description": .string("Scan duration in seconds (default: 5)")]),
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
                    "device_id":    .object(["type": .string("string"), "description": .string("Device UUID to connect to")]),
                    "name":         .object(["type": .string("string"), "description": .string("Connect to device matching this name (substring)")]),
                    "service":      .object(["type": .string("string"), "description": .string("Filter by advertised service UUID")]),
                    "manufacturer": .object(["type": .string("integer"), "description": .string("Filter by manufacturer ID")]),
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
                    "format":    .object(["type": .string("string"), "enum": .array([.string("hex"), .string("utf8"), .string("uint8"), .string("uint16le"), .string("uint32le"), .string("float32le"), .string("base64"), .string("raw")]), "description": .string("Output format (default: hex)")]),
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
                    "format":        .object(["type": .string("string"), "enum": .array([.string("hex"), .string("utf8"), .string("uint8"), .string("uint16le"), .string("uint32le"), .string("float32le"), .string("base64"), .string("raw")]), "description": .string("Input format (default: hex)")]),
                    "with_response": .object(["type": .string("boolean"), "description": .string("true = write with response, false = without response, omit = auto")]),
                ]) { $1 }),
                "required": .array([.string("char_uuid"), .string("data")]),
            ]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
        ),
        Tool(
            name: "ble_subscribe",
            description: "Subscribe to notifications on a GATT characteristic. Collects notifications for the specified duration or count (defaults to count=10), then returns all values at once.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(targetingProperties.merging([
                    "char_uuid": .object(["type": .string("string"), "description": .string("Characteristic UUID to subscribe to")]),
                    "format":    .object(["type": .string("string"), "enum": .array([.string("hex"), .string("utf8"), .string("uint8"), .string("uint16le"), .string("uint32le"), .string("float32le"), .string("base64"), .string("raw")]), "description": .string("Value format (default: hex)")]),
                    "duration":  .object(["type": .string("number"), "description": .string("Collection duration in seconds")]),
                    "count":     .object(["type": .string("integer"), "description": .string("Number of notifications to collect (default: 10)")]),
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
                    "format":    .object(["type": .string("string"), "description": .string("Value format (default: hex)")]),
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
                    "format":    .object(["type": .string("string"), "description": .string("Value format (default: hex)")]),
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
    ]

    static let targetingProperties: [String: Value] = [
        "name":         .object(["type": .string("string"), "description": .string("Device name filter (substring match)")]),
        "device_id":    .object(["type": .string("string"), "description": .string("Device UUID")]),
        "service":      .object(["type": .string("string"), "description": .string("Service UUID filter")]),
        "manufacturer": .object(["type": .string("integer"), "description": .string("Manufacturer ID filter")]),
        "rssi_min":     .object(["type": .string("integer"), "description": .string("Minimum RSSI threshold")]),
        "pick":         .object(["type": .string("string"), "enum": .array([.string("strongest"), .string("first"), .string("only")]), "description": .string("Auto-select strategy")]),
    ]
}
