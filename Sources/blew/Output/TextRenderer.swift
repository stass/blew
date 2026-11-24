import Foundation
import BLEManager

/// Human-readable output. Every stdout line is a `TextLine` written by
/// `OutputFormatter.write`; a `TextLine` escapes all the text it holds, and
/// its styles become blew's own ANSI bold and dim. stderr lines go through
/// `StandardErrorLog`, raw `nus` bytes through `StandardOutput.writeRaw`.
final class TextRenderer: OutputRenderer {
    let verbosity: Int
    let formatter: OutputFormatter

    init(verbosity: Int) {
        self.verbosity = verbosity
        self.formatter = OutputFormatter(format: .text, verbosity: verbosity)
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
            renderGATTTree(tree)
        case .characteristicInfo(let info):
            renderCharacteristicInfo(info)
        case .connectionStatus(let status):
            renderConnectionStatus(status)
        case .peripheralStatus(let status):
            renderPeripheralStatus(status)
        case .readValue(let result):
            write(TextLine(result.value))
        case .writeSuccess:
            break
        case .notification(let nv):
            write(TextLine(nv.value))
        case .notificationsDropped(let drops):
            // stderr, so stdout carries only the values.
            StandardErrorLog.write("sub ", drops.text)
        case .peripheralSummary(let summary):
            renderPeriphSummary(summary)
        case .peripheralEvent(let record):
            renderPeriphEvent(record)
        case .subscriptionList(let uuids):
            renderSubscriptionList(uuids)
        case .nusData(let record):
            // A UART's bytes, unchanged: no newline, no decoding.
            StandardOutput.writeRaw(record)
        case .nusStatus(let status):
            // stderr, so stdout carries only the device's bytes.
            let detail = status.detail.isEmpty ? "" : ": \(status.detail)"
            StandardErrorLog.write("nus ", "\(status.event)\(detail)")
        case .message(let msg):
            write(TextLine(msg))
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

    // MARK: - Devices table

    private func renderDevices(_ devices: [DeviceRow]) {
        let headers: [ColumnHeader] = ["ID", "Name", "RSSI", "Signal", "Services"]
        let rows: [[String]] = devices.map { d in
            [
                d.id,
                d.name ?? "(unknown)",
                "\(d.rssi)",
                rssiBar(d.rssi),
                d.serviceDisplayNames.joined(separator: ", "),
            ]
        }
        formatter.printTable(headers: headers, rows: rows)
    }

    // MARK: - Services table

    private func renderServices(_ services: [ServiceRow]) {
        let headers: [ColumnHeader] = ["UUID", "Name", "Primary"]
        let rows = services.map { svc -> [String] in
            [svc.uuid, svc.name ?? "", svc.isPrimary ? "yes" : "no"]
        }
        formatter.printTable(headers: headers, rows: rows)
    }

    // MARK: - Characteristics table

    private func renderCharacteristics(_ chars: [CharacteristicRow]) {
        let hasValues = chars.contains { LabeledValue.flattened(value: $0.value, fields: $0.valueFields) != nil }
        guard hasValues else {
            let rows = chars.map { char -> [String] in
                [char.uuid, char.name ?? "", char.properties.joined(separator: ",")]
            }
            formatter.printTable(headers: ["UUID", "Name", "Properties"], rows: rows)
            return
        }
        // The value follows the padded columns unpadded; a multi-field value
        // is one `label: value` line per field under the row.
        let rows = chars.map { char -> TextTable.Row in
            let cells = [char.uuid, char.name ?? "", char.properties.joined(separator: ",")]
            if let fields = char.valueFields, fields.count > 1 {
                return TextTable.Row(cells: cells, continuation: fields.map { fieldLine($0) })
            }
            return TextTable.Row(cells: cells, trailing: TextLine(char.value ?? ""))
        }
        write(TextTable.lines(headers: ["UUID", "Name", "Properties"], trailingHeader: "Value", rows: rows))
    }

    // MARK: - Descriptors table

    private func renderDescriptors(_ descs: [DescriptorRow]) {
        let headers: [ColumnHeader] = ["UUID", "Name"]
        let rows = descs.map { [$0.uuid, $0.name ?? ""] }
        formatter.printTable(headers: headers, rows: rows)
    }

    // MARK: - GATT tree

    private func renderGATTTree(_ tree: [GATTTreeService]) {
        for (svcIdx, service) in tree.enumerated() {
            var svcLine = TextLine("Service ")
            svcLine.append(service.uuid, .bold)
            if let name = service.name { svcLine.append("  \(name)") }
            write(svcLine)

            for (charIdx, char) in service.characteristics.enumerated() {
                let isLastChar = charIdx == service.characteristics.count - 1
                let charBranch = isLastChar ? "└── " : "├── "
                let descIndent = isLastChar ? "    " : "│   "

                var charLine = TextLine(charBranch)
                charLine.append(char.uuid, .bold)
                if let name = char.name { charLine.append("  \(name)") }
                charLine.append("  ")
                charLine.append("[\(char.properties.joined(separator: ", "))]", .dim)

                if let fields = char.valueFields, fields.count > 1 {
                    write(charLine)
                    for lv in fields {
                        write(fieldLine(lv, indent: descIndent + "  "))
                    }
                } else if let value = char.value {
                    charLine.append("  = ", .dim)
                    charLine.append(value)
                    write(charLine)
                } else {
                    write(charLine)
                }

                for (descIdx, desc) in char.descriptors.enumerated() {
                    let isLastDesc = descIdx == char.descriptors.count - 1
                    var descLine = TextLine(descIndent + (isLastDesc ? "└── " : "├── "))
                    descLine.append(desc.uuid, .dim)
                    if let name = desc.name { descLine.append("  \(name)", .dim) }
                    write(descLine)
                }
            }

            if svcIdx < tree.count - 1 { write(TextLine()) }
        }
    }

    // MARK: - Characteristic info

    private func renderCharacteristicInfo(_ info: GATTCharInfo) {
        write(TextLine("\(info.name) (\(info.uuid))", .bold))
        write(TextLine())
        write(TextLine(info.description))
        guard !info.fields.isEmpty else { return }
        write(TextLine())
        write(TextLine("Structure:", .bold))
        let rows = info.fields.map { f -> TextTable.Row in
            var trailing = TextLine(f.sizeDescription)
            if let cond = f.conditionDescription {
                trailing.append("  ")
                trailing.append("[\(cond)]", .dim)
            }
            return TextTable.Row(cells: [f.name, f.typeName], trailing: trailing)
        }
        write(TextTable.lines(headers: nil, indent: 2, rows: rows))
    }

    // MARK: - Connection status

    private func renderConnectionStatus(_ status: ConnectionStatus) {
        formatter.printRecord(
            ("connected", status.isConnected ? "yes" : "no"),
            ("device", status.deviceId ?? "(none)"),
            ("name", status.deviceName ?? "(none)"),
            ("services", "\(status.servicesCount)"),
            ("characteristics", "\(status.characteristicsCount)"),
            ("subscriptions", "\(status.subscriptionsCount)")
        )
        if let lastError = status.lastError {
            formatter.printRecord(("last_error", lastError))
        }
    }

    // MARK: - Peripheral status

    private func renderPeripheralStatus(_ status: PeripheralStatus) {
        formatter.printRecord(
            ("advertising", status.isAdvertising ? "yes" : "no"),
            ("name", status.advertisedName ?? "(none)"),
            ("services", "\(status.serviceCount)"),
            ("characteristics", "\(status.characteristicCount)"),
            ("subscribers", "\(status.subscriberCount)")
        )
    }

    // MARK: - Peripheral summary

    private func renderPeriphSummary(_ summary: PeriphSummaryResult) {
        let displayUUIDs = summary.serviceUUIDs.map { BLENames.displayUUID($0, category: .service) }.joined(separator: ", ")
        write(TextLine("Advertising \"\(summary.name)\" [\(displayUUIDs)]"))

        for svc in summary.services where !svc.characteristics.isEmpty {
            let svcDisplay = BLENames.displayUUID(svc.uuid.string, category: .service)
            write(TextLine("  Service \(svcDisplay)"))
            for char in svc.characteristics {
                let charDisplay = BLENames.displayUUID(char.uuid.string, category: .characteristic)
                let props = char.properties.map { $0.rawValue }.joined(separator: ", ")
                write(TextLine("  +-- \(charDisplay) [\(props)]"))
            }
        }
    }

    // MARK: - Peripheral event

    private func renderPeriphEvent(_ record: PeriphEventRecord) {
        let ts = record.timestamp
        switch record.event {
        case .stateChanged(let state):
            renderInfo("[\(ts)] Bluetooth state: \(state.rawValue)")
        case .advertisingStarted(let error):
            if let error = error {
                renderError("[\(ts)] advertising failed: \(error)")
            }
        case .serviceAdded(_, let error):
            if let error = error {
                renderError("[\(ts)] service add failed: \(error)")
            }
        case .centralConnected(let id):
            write(TextLine("[\(ts)] central \(shortId(id)) connected"))
        case .centralDisconnected(let id):
            write(TextLine("[\(ts)] central \(shortId(id)) disconnected"))
        case .readRequest(let id, let uuid):
            write(TextLine("[\(ts)] read \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id))"))
        case .writeRequest(let id, let uuid, let value):
            let hex = DataFormatter.format(value, as: .hex)
            write(TextLine("[\(ts)] write \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id)) <- \(hex)"))
        case .subscribed(let id, let uuid):
            write(TextLine("[\(ts)] subscribe \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id))"))
        case .unsubscribed(let id, let uuid):
            write(TextLine("[\(ts)] unsubscribe \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id))"))
        case .notificationSent(let uuid, let count):
            renderInfo("[\(ts)] notification sent on \(uuid) to \(count) subscriber(s)")
        }
    }

    // MARK: - Subscription list

    private func renderSubscriptionList(_ uuids: [String]) {
        if uuids.isEmpty {
            write(TextLine("No active background subscriptions."))
        } else {
            write(TextLine("Active background subscriptions:"))
            for uuid in uuids {
                write(TextLine("  \(BLENames.displayUUID(uuid, category: .characteristic))"))
            }
        }
    }

    // MARK: - Helpers

    private func write(_ line: TextLine) {
        formatter.write(line)
    }

    private func write(_ lines: [TextLine]) {
        formatter.write(lines)
    }

    /// `indent` and `label: ` in one dim run, then the value. The GATT tree
    /// passes its box-drawing prefix as `indent`; the characteristics table
    /// indents by columns through `TextTable.Row.continuation`.
    private func fieldLine(_ lv: LabeledValue, indent: String = "") -> TextLine {
        var line = TextLine("\(indent)\(lv.label): ", .dim)
        line.append(lv.value)
        return line
    }

    private func shortId(_ uuidString: String) -> String {
        String(uuidString.prefix(8))
    }

    static func rssiBar(_ rssi: Int, width: Int = 8) -> String {
        let clamped = max(-100, min(-30, rssi))
        let ratio = Double(clamped + 100) / 70.0
        let filled = Int((ratio * Double(width)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    private func rssiBar(_ rssi: Int) -> String {
        Self.rssiBar(rssi)
    }
}
