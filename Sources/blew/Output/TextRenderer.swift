import Foundation
import BLEManager

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
            Swift.print(result.value)
        case .writeSuccess:
            break
        case .notification(let nv):
            Swift.print(nv.value)
        case .peripheralSummary(let summary):
            renderPeriphSummary(summary)
        case .peripheralEvent(let record):
            renderPeriphEvent(record)
        case .subscriptionList(let uuids):
            renderSubscriptionList(uuids)
        case .message(let msg):
            Swift.print(msg)
        case .empty:
            break
        }
    }

    func renderError(_ message: String) {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }

    func renderInfo(_ message: String) {
        guard verbosity >= 1 else { return }
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    func renderDebug(_ message: String) {
        guard verbosity >= 2 else { return }
        FileHandle.standardError.write(Data("[debug] \(message)\n".utf8))
    }

    func renderLive(_ text: String) {
        FileHandle.standardError.write(Data("\r\u{1B}[K\(text)\r\n".utf8))
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
        let hasValues = chars.contains { $0.value != nil }
        if hasValues {
            let headers = ["UUID", "Name", "Properties", "Value"]
            let uuidW  = chars.map { $0.uuid.count }.max().map { max($0, headers[0].count) } ?? headers[0].count
            let nameW  = chars.map { ($0.name ?? "").count }.max().map { max($0, headers[1].count) } ?? headers[1].count
            let propsW = chars.map { $0.properties.joined(separator: ",").count }.max().map { max($0, headers[2].count) } ?? headers[2].count

            let headerLine = [
                formatter.bold(headers[0]).padding(toLength: uuidW  + formatter.boldPaddingWidth, withPad: " ", startingAt: 0),
                formatter.bold(headers[1]).padding(toLength: nameW  + formatter.boldPaddingWidth, withPad: " ", startingAt: 0),
                formatter.bold(headers[2]).padding(toLength: propsW + formatter.boldPaddingWidth, withPad: " ", startingAt: 0),
                formatter.bold(headers[3]),
            ].joined(separator: "  ")
            let sepWidth = uuidW + 2 + nameW + 2 + propsW + 2 + headers[3].count
            Swift.print(headerLine)
            Swift.print(formatter.dim(String(repeating: "─", count: sepWidth)))
            let valueIndent = String(repeating: " ", count: uuidW + 2 + nameW + 2 + propsW + 2)
            for row in chars {
                let props = row.properties.joined(separator: ",")
                if let fields = row.valueFields, fields.count > 1 {
                    let rowLine = [
                        row.uuid.padding(toLength: uuidW,  withPad: " ", startingAt: 0),
                        (row.name ?? "").padding(toLength: nameW,  withPad: " ", startingAt: 0),
                        props.padding(toLength: propsW, withPad: " ", startingAt: 0),
                    ].joined(separator: "  ")
                    Swift.print(rowLine)
                    for lv in fields {
                        Swift.print(formatter.dim(valueIndent + lv.label + ": ") + lv.value)
                    }
                } else {
                    let value = row.value ?? ""
                    let rowLine = [
                        row.uuid.padding(toLength: uuidW,  withPad: " ", startingAt: 0),
                        (row.name ?? "").padding(toLength: nameW,  withPad: " ", startingAt: 0),
                        props.padding(toLength: propsW, withPad: " ", startingAt: 0),
                    ].joined(separator: "  ")
                    if !value.isEmpty {
                        Swift.print(rowLine + "  " + value)
                    } else {
                        Swift.print(rowLine)
                    }
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
            var svcLine = "Service \(formatter.bold(service.uuid))"
            if let name = service.name { svcLine += "  \(name)" }
            Swift.print(svcLine)

            for (charIdx, char) in service.characteristics.enumerated() {
                let isLastChar = charIdx == service.characteristics.count - 1
                let charBranch = isLastChar ? "└── " : "├── "
                let descIndent = isLastChar ? "    " : "│   "
                let valueIndent = descIndent + "  "

                let props = char.properties.joined(separator: ", ")
                var charLine = charBranch + formatter.bold(char.uuid)
                if let name = char.name { charLine += "  \(name)" }
                charLine += "  \(formatter.dim("[\(props)]"))"

                if let fields = char.valueFields, fields.count > 1 {
                    Swift.print(charLine)
                    for lv in fields {
                        Swift.print(formatter.dim(valueIndent + lv.label + ": ") + lv.value)
                    }
                } else if let value = char.value {
                    Swift.print(charLine + formatter.dim("  = ") + value)
                } else {
                    Swift.print(charLine)
                }

                for (descIdx, desc) in char.descriptors.enumerated() {
                    let isLastDesc = descIdx == char.descriptors.count - 1
                    let descBranch = isLastDesc ? "└── " : "├── "
                    var descLine = descIndent + descBranch + formatter.dim(desc.uuid)
                    if let name = desc.name { descLine += formatter.dim("  \(name)") }
                    Swift.print(descLine)
                }
            }

            if svcIdx < tree.count - 1 { Swift.print("") }
        }
    }

    // MARK: - Characteristic info

    private func renderCharacteristicInfo(_ info: GATTCharInfo) {
        Swift.print("\(formatter.bold("\(info.name) (\(info.uuid))"))")
        Swift.print("")
        Swift.print(info.description)
        if !info.fields.isEmpty {
            Swift.print("")
            Swift.print(formatter.bold("Structure:"))
            let nameWidth = info.fields.map { $0.name.count }.max() ?? 0
            let typeWidth = info.fields.map { $0.typeName.count }.max() ?? 0
            for f in info.fields {
                var line = "  \(f.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))"
                line += "  \(f.typeName.padding(toLength: typeWidth, withPad: " ", startingAt: 0))"
                line += "  \(f.sizeDescription)"
                if let cond = f.conditionDescription {
                    line += "  \(formatter.dim("[\(cond)]"))"
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
        Swift.print("Advertising \"\(summary.name)\" [\(displayUUIDs)]")

        for svc in summary.services where !svc.characteristics.isEmpty {
            let svcDisplay = BLENames.displayUUID(svc.uuid, category: .service)
            Swift.print("  Service \(svcDisplay)")
            for char in svc.characteristics {
                let charDisplay = BLENames.displayUUID(char.uuid, category: .characteristic)
                let props = char.properties.map { $0.rawValue }.joined(separator: ", ")
                Swift.print("  +-- \(charDisplay) [\(props)]")
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
            Swift.print("[\(ts)] central \(shortId(id)) connected")
        case .centralDisconnected(let id):
            Swift.print("[\(ts)] central \(shortId(id)) disconnected")
        case .readRequest(let id, let uuid):
            Swift.print("[\(ts)] read \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id))")
        case .writeRequest(let id, let uuid, let value):
            let hex = DataFormatter.format(value, as: "hex")
            Swift.print("[\(ts)] write \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id)) <- \(hex)")
        case .subscribed(let id, let uuid):
            Swift.print("[\(ts)] subscribe \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id))")
        case .unsubscribed(let id, let uuid):
            Swift.print("[\(ts)] unsubscribe \(BLENames.displayUUID(uuid, category: .characteristic)) by \(shortId(id))")
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
                Swift.print("  \(BLENames.displayUUID(uuid, category: .characteristic))")
            }
        }
    }

    // MARK: - Helpers

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
