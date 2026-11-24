import Foundation
import BLEManager

/// Machine-readable output: one `key=value` record per line, every value
/// through `KVText.value` (README, "Key-value output"), written by
/// `StandardOutput`. Lines on stderr go through `StandardErrorLog`, like
/// the text renderer's.
final class KVRenderer: OutputRenderer {
    let verbosity: Int
    /// The stderr lines, shared with the text renderer, and `.message` lines.
    private let formatter: OutputFormatter

    init(verbosity: Int) {
        self.verbosity = verbosity
        self.formatter = OutputFormatter(format: .kv, verbosity: verbosity)
    }

    func render(_ output: CommandOutput) {
        switch output {
        case .devices(let devices):
            renderDevices(devices)
        case .services(let services):
            renderServices(services)
        case .characteristics(let chars):
            renderCharacteristics(chars)
        case .descriptors(let descs):
            renderDescriptors(descs)
        case .gattTree(let tree):
            renderGATTTreeKV(tree)
        case .characteristicInfo(let info):
            renderCharacteristicInfoKV(info)
        case .connectionStatus(let status):
            renderConnectionStatus(status)
        case .peripheralStatus(let status):
            renderPeripheralStatus(status)
        case .readValue(let result):
            var pairs: [(KVKey, String)] = [("char", result.char)]
            if let name = result.name { pairs.append(("name", name)) }
            pairs.append(("value", result.value))
            pairs.append(("fmt", result.format.rawValue))
            printKV(pairs)
        case .writeSuccess:
            break
        case .notification(let nv):
            var pairs: [(KVKey, String)] = [("ts", nv.timestamp), ("char", nv.char)]
            if let name = nv.name { pairs.append(("name", name)) }
            pairs.append(("value", nv.value))
            printKV(pairs)
        case .peripheralSummary(let summary):
            printKV([
                ("name", summary.name),
                ("services", summary.serviceUUIDs.joined(separator: ",")),
            ])
        case .peripheralEvent(let record):
            renderPeriphEventKV(record)
        case .subscriptionList(let uuids):
            for uuid in uuids {
                printKV([("subscription", uuid)])
            }
        case .nusData(let record):
            printKV([("ts", record.timestamp), ("rx", DataFormatter.format(record.data, as: .hex))])
        case .notificationsDropped(let drops):
            printKV([("sub", "dropped"), ("char", drops.char), ("total", "\(drops.total)")])
        case .nusStatus(let status):
            printKV([("nus", status.event), ("detail", status.detail)])
        case .nusDropped(let drops):
            printKV([("nus", "dropped"), ("detail", drops.detail)])
        case .message(let msg):
            formatter.write(TextLine(msg))
        case .empty:
            break
        }
    }

    func renderError(_ message: String) {
        formatter.printError(message)
    }

    func renderInfo(_ message: String) {
        formatter.printInfo(message)
    }

    func renderDebug(_ message: String) {
        formatter.printDebug(message)
    }

    func renderLive(_ text: String) {
        StandardErrorLog.writeLive(text)
    }

    // MARK: - KV formatting

    private func printKV(_ pairs: [(KVKey, String)]) {
        StandardOutput.write(record: pairs)
    }

    private func printTable(headers: [ColumnHeader], rows: [[String]]) {
        StandardOutput.write(recordsWithHeaders: headers, rows: rows)
    }

    // MARK: - Devices

    private func renderDevices(_ devices: [DeviceRow]) {
        let headers: [ColumnHeader] = ["ID", "Name", "RSSI", "Services"]
        let rows: [[String]] = devices.map { d in
            [
                d.id,
                d.name ?? "(unknown)",
                "\(d.rssi)",
                d.serviceUUIDs.joined(separator: ","),
            ]
        }
        printTable(headers: headers, rows: rows)
    }

    // MARK: - Services

    private func renderServices(_ services: [ServiceRow]) {
        let headers: [ColumnHeader] = ["UUID", "Name", "Primary"]
        let rows = services.map { [$0.uuid, $0.name ?? "", $0.isPrimary ? "yes" : "no"] }
        printTable(headers: headers, rows: rows)
    }

    // MARK: - Characteristics

    private func renderCharacteristics(_ chars: [CharacteristicRow]) {
        let hasValues = chars.contains { LabeledValue.flattened(value: $0.value, fields: $0.valueFields) != nil }
        if hasValues {
            let headers: [ColumnHeader] = ["UUID", "Name", "Properties", "Value"]
            let rows = chars.map { char -> [String] in
                [char.uuid, char.name ?? "", char.properties.joined(separator: ","),
                 LabeledValue.flattened(value: char.value, fields: char.valueFields) ?? ""]
            }
            printTable(headers: headers, rows: rows)
        } else {
            let rows = chars.map { char -> [String] in
                [char.uuid, char.name ?? "", char.properties.joined(separator: ",")]
            }
            printTable(headers: ["UUID", "Name", "Properties"], rows: rows)
        }
    }

    // MARK: - Descriptors

    private func renderDescriptors(_ descs: [DescriptorRow]) {
        let rows = descs.map { [$0.uuid, $0.name ?? ""] }
        printTable(headers: ["UUID", "Name"], rows: rows)
    }

    // MARK: - GATT tree (KV)

    private func renderGATTTreeKV(_ tree: [GATTTreeService]) {
        for service in tree {
            var svcPairs: [(KVKey, String)] = [("type", "service"), ("uuid", service.uuid)]
            if let name = service.name { svcPairs.append(("name", name)) }
            printKV(svcPairs)
            for char in service.characteristics {
                var charPairs: [(KVKey, String)] = [
                    ("type", "characteristic"),
                    ("service", service.uuid),
                    ("uuid", char.uuid),
                ]
                if let name = char.name { charPairs.append(("name", name)) }
                charPairs.append(("properties", char.properties.joined(separator: ",")))
                if let value = LabeledValue.flattened(value: char.value, fields: char.valueFields) {
                    charPairs.append(("value", value))
                }
                printKV(charPairs)
                for desc in char.descriptors {
                    var descPairs: [(KVKey, String)] = [
                        ("type", "descriptor"),
                        ("char", char.uuid),
                        ("uuid", desc.uuid),
                    ]
                    if let name = desc.name { descPairs.append(("name", name)) }
                    printKV(descPairs)
                }
            }
        }
    }

    // MARK: - Characteristic info (KV)

    private func renderCharacteristicInfoKV(_ info: GATTCharInfo) {
        printKV([("uuid", info.uuid), ("name", info.name), ("description", info.description)])
        for f in info.fields {
            var pairs: [(KVKey, String)] = [
                ("field", f.name),
                ("type", f.typeName),
                ("size", f.sizeDescription),
            ]
            if let cond = f.conditionDescription {
                pairs.append(("condition", cond))
            }
            printKV(pairs)
        }
    }

    // MARK: - Connection status

    private func renderConnectionStatus(_ status: ConnectionStatus) {
        var pairs: [(KVKey, String)] = [
            ("connected", status.isConnected ? "yes" : "no"),
            ("device", status.deviceId ?? "(none)"),
            ("name", status.deviceName ?? "(none)"),
            ("services", "\(status.servicesCount)"),
            ("characteristics", "\(status.characteristicsCount)"),
            ("subscriptions", "\(status.subscriptionsCount)"),
        ]
        if let lastError = status.lastError {
            pairs.append(("last_error", lastError))
        }
        printKV(pairs)
    }

    // MARK: - Peripheral status

    private func renderPeripheralStatus(_ status: PeripheralStatus) {
        printKV([
            ("advertising", status.isAdvertising ? "yes" : "no"),
            ("name", status.advertisedName ?? "(none)"),
            ("services", "\(status.serviceCount)"),
            ("characteristics", "\(status.characteristicCount)"),
            ("subscribers", "\(status.subscriberCount)"),
        ])
    }

    // MARK: - Peripheral event (KV)

    private func renderPeriphEventKV(_ record: PeriphEventRecord) {
        let ts = record.timestamp
        switch record.event {
        case .stateChanged, .advertisingStarted, .serviceAdded:
            break
        case .centralConnected(let id):
            printKV([("event", "connected"), ("ts", ts), ("central", id)])
        case .centralDisconnected(let id):
            printKV([("event", "disconnected"), ("ts", ts), ("central", id)])
        case .readRequest(let id, let uuid):
            printKV([("event", "read"), ("ts", ts), ("central", id), ("char", uuid)])
        case .writeRequest(let id, let uuid, let value):
            printKV([("event", "write"), ("ts", ts), ("central", id), ("char", uuid), ("value", DataFormatter.format(value, as: .hex))])
        case .subscribed(let id, let uuid):
            printKV([("event", "subscribe"), ("ts", ts), ("central", id), ("char", uuid)])
        case .unsubscribed(let id, let uuid):
            printKV([("event", "unsubscribe"), ("ts", ts), ("central", id), ("char", uuid)])
        case .notificationSent(let uuid, let count):
            printKV([("event", "notification"), ("ts", ts), ("char", uuid), ("subscribers", "\(count)")])
        }
    }
}
