import Foundation
import BLEManager

/// Human-readable output. Every string from a device, a config file or an
/// argument passes through `TerminalText.escape` (directly, or inside
/// `OutputFormatter.formatTable`/`printRecord` and `StandardErrorLog`)
/// before it reaches the terminal; blew's own ANSI bold and dim are added
/// around the escaped text.
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
            Swift.print(esc(result.value))
        case .writeSuccess:
            break
        case .notification(let nv):
            Swift.print(esc(nv.value))
        case .peripheralSummary(let summary):
            renderPeriphSummary(summary)
        case .peripheralEvent(let record):
            renderPeriphEvent(record)
        case .subscriptionList(let uuids):
            renderSubscriptionList(uuids)
        case .nusData(let record):
            // A UART's bytes, unchanged: no newline, no decoding.
            fflush(stdout)
            FileHandle.standardOutput.write(record.data)
        case .nusStatus(let status):
            // stderr, so stdout carries only the device's bytes.
            let detail = status.detail.isEmpty ? "" : ": \(status.detail)"
            StandardErrorLog.write("nus ", "\(status.event)\(detail)")
        case .message(let msg):
            Swift.print(esc(msg))
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
        let headers = ["ID", "Name", "RSSI", "Signal", "Services"]
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
        let headers = ["UUID", "Name", "Primary"]
        let rows = services.map { svc -> [String] in
            [svc.uuid, svc.name ?? "", svc.isPrimary ? "yes" : "no"]
        }
        formatter.printTable(headers: headers, rows: rows)
    }

    // MARK: - Characteristics table

    private func renderCharacteristics(_ chars: [CharacteristicRow]) {
        let hasValues = chars.contains { LabeledValue.flattened(value: $0.value, fields: $0.valueFields) != nil }
        if hasValues {
            // Like `OutputFormatter.formatTable` for the first three columns;
            // the value follows them unpadded, a multi-field value as one
            // indented `label: value` line per field.
            let headers = ["UUID", "Name", "Properties", "Value"]
            let cells = chars.map { [esc($0.uuid), esc($0.name ?? ""), esc($0.properties.joined(separator: ","))] }
            var widths = headers.prefix(3).map(TerminalText.width)
            for row in cells {
                for i in widths.indices { widths[i] = max(widths[i], TerminalText.width(row[i])) }
            }
            let leading = { (row: [String]) in
                row.indices.map { TerminalText.pad(row[$0], toWidth: widths[$0]) }.joined(separator: "  ")
            }
            let headerLine = (headers.prefix(3).indices.map {
                formatter.bold(TerminalText.pad(headers[$0], toWidth: widths[$0]))
            } + [formatter.bold(headers[3])]).joined(separator: "  ")
            let indentWidth = widths.reduce(0, +) + 2 * widths.count
            Swift.print(headerLine)
            Swift.print(formatter.dim(String(repeating: "─", count: indentWidth + TerminalText.width(headers[3]))))
            let valueIndent = String(repeating: " ", count: indentWidth)
            for (row, rowCells) in zip(chars, cells) {
                if let fields = row.valueFields, fields.count > 1 {
                    Swift.print(leading(rowCells))
                    for lv in fields {
                        Swift.print(formatter.dim(valueIndent + esc(lv.label) + ": ") + esc(lv.value))
                    }
                } else {
                    let value = esc(row.value ?? "")
                    Swift.print(value.isEmpty ? leading(rowCells) : leading(rowCells) + "  " + value)
                }
            }
        } else {
            let rows = chars.map { char -> [String] in
                [char.uuid, char.name ?? "", char.properties.joined(separator: ",")]
            }
            formatter.printTable(headers: ["UUID", "Name", "Properties"], rows: rows)
        }
    }

    // MARK: - Descriptors table

    private func renderDescriptors(_ descs: [DescriptorRow]) {
        let headers = ["UUID", "Name"]
        let rows = descs.map { [$0.uuid, $0.name ?? ""] }
        formatter.printTable(headers: headers, rows: rows)
    }

    // MARK: - GATT tree

    private func renderGATTTree(_ tree: [GATTTreeService]) {
        for (svcIdx, service) in tree.enumerated() {
            var svcLine = "Service \(formatter.bold(esc(service.uuid)))"
            if let name = service.name { svcLine += "  \(esc(name))" }
            Swift.print(svcLine)

            for (charIdx, char) in service.characteristics.enumerated() {
                let isLastChar = charIdx == service.characteristics.count - 1
                let charBranch = isLastChar ? "└── " : "├── "
                let descIndent = isLastChar ? "    " : "│   "
                let valueIndent = descIndent + "  "

                let props = esc(char.properties.joined(separator: ", "))
                var charLine = charBranch + formatter.bold(esc(char.uuid))
                if let name = char.name { charLine += "  \(esc(name))" }
                charLine += "  \(formatter.dim("[\(props)]"))"

                if let fields = char.valueFields, fields.count > 1 {
                    Swift.print(charLine)
                    for lv in fields {
                        Swift.print(formatter.dim(valueIndent + esc(lv.label) + ": ") + esc(lv.value))
                    }
                } else if let value = char.value {
                    Swift.print(charLine + formatter.dim("  = ") + esc(value))
                } else {
                    Swift.print(charLine)
                }

                for (descIdx, desc) in char.descriptors.enumerated() {
                    let isLastDesc = descIdx == char.descriptors.count - 1
                    let descBranch = isLastDesc ? "└── " : "├── "
                    var descLine = descIndent + descBranch + formatter.dim(esc(desc.uuid))
                    if let name = desc.name { descLine += formatter.dim("  \(esc(name))") }
                    Swift.print(descLine)
                }
            }

            if svcIdx < tree.count - 1 { Swift.print("") }
        }
    }

    // MARK: - Characteristic info

    private func renderCharacteristicInfo(_ info: GATTCharInfo) {
        Swift.print(formatter.bold(esc("\(info.name) (\(info.uuid))")))
        Swift.print("")
        Swift.print(esc(info.description))
        if !info.fields.isEmpty {
            Swift.print("")
            Swift.print(formatter.bold("Structure:"))
            let names = info.fields.map { esc($0.name) }
            let types = info.fields.map { esc($0.typeName) }
            let nameWidth = names.map(TerminalText.width).max() ?? 0
            let typeWidth = types.map(TerminalText.width).max() ?? 0
            for (i, f) in info.fields.enumerated() {
                var line = "  \(TerminalText.pad(names[i], toWidth: nameWidth))"
                line += "  \(TerminalText.pad(types[i], toWidth: typeWidth))"
                line += "  \(esc(f.sizeDescription))"
                if let cond = f.conditionDescription {
                    line += "  \(formatter.dim("[\(esc(cond))]"))"
                }
                Swift.print(line)
            }
        }
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
        Swift.print(esc("Advertising \"\(summary.name)\" [\(displayUUIDs)]"))

        for svc in summary.services where !svc.characteristics.isEmpty {
            let svcDisplay = BLENames.displayUUID(svc.uuid.string, category: .service)
            Swift.print(esc("  Service \(svcDisplay)"))
            for char in svc.characteristics {
                let charDisplay = BLENames.displayUUID(char.uuid.string, category: .characteristic)
                let props = char.properties.map { $0.rawValue }.joined(separator: ", ")
                Swift.print(esc("  +-- \(charDisplay) [\(props)]"))
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
            Swift.print(esc("[\(ts)] central \(shortId(id)) connected"))
        case .centralDisconnected(let id):
            Swift.print(esc("[\(ts)] central \(shortId(id)) disconnected"))
        case .readRequest(let id, let uuid):
            Swift.print(esc("[\(ts)] read \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id))"))
        case .writeRequest(let id, let uuid, let value):
            let hex = DataFormatter.format(value, as: "hex")
            Swift.print(esc("[\(ts)] write \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id)) <- \(hex)"))
        case .subscribed(let id, let uuid):
            Swift.print(esc("[\(ts)] subscribe \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id))"))
        case .unsubscribed(let id, let uuid):
            Swift.print(esc("[\(ts)] unsubscribe \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id))"))
        case .notificationSent(let uuid, let count):
            renderInfo("[\(ts)] notification sent on \(uuid) to \(count) subscriber(s)")
        }
    }

    // MARK: - Subscription list

    private func renderSubscriptionList(_ uuids: [String]) {
        if uuids.isEmpty {
            Swift.print("No active background subscriptions.")
        } else {
            Swift.print("Active background subscriptions:")
            for uuid in uuids {
                Swift.print(esc("  \(BLENames.displayUUID(uuid, category: .characteristic))"))
            }
        }
    }

    // MARK: - Helpers

    private func esc(_ text: String) -> String {
        TerminalText.escape(text)
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
