import BLEManager
import Foundation

// Device selection: which advertising device a command means. Everything
// here is a pure function of the command's arguments, the scan results and
// the connection state, so it is tested without a radio. CommandRouter runs
// the scans and connections these functions decide on.

/// The advertisement filters of the device-targeting options. A device
/// matches when it passes every filter that is set.
struct DeviceFilter: Equatable {
    /// `-i`: the device identifier, compared without regard to case.
    var id: String?
    /// `-n`: a substring of the advertised name, compared without regard to case.
    var name: String?
    /// `-S`, in the form `BLENames.canonicalUUID` gives: the device must
    /// advertise every one of them.
    var services: [String] = []
    /// `-m`: the Bluetooth SIG company identifier that starts the
    /// manufacturer data (its first two bytes, little-endian).
    var manufacturer: UInt16?
    /// `-R`: the lowest RSSI, in dBm.
    var rssiMin: Int?

    /// True when no filter is set, so the options name no device.
    var isEmpty: Bool { self == DeviceFilter() }

    func matches(_ device: DiscoveredDevice) -> Bool {
        if let id, device.identifier.caseInsensitiveCompare(id) != .orderedSame { return false }
        if let name {
            guard let deviceName = device.name, deviceName.localizedCaseInsensitiveContains(name) else { return false }
        }
        if !services.isEmpty {
            let advertised = Set(device.serviceUUIDs.map { BLENames.canonicalUUID($0) ?? $0.uppercased() })
            guard services.allSatisfy(advertised.contains) else { return false }
        }
        if let manufacturer {
            guard let data = device.manufacturerData, data.count >= 2 else { return false }
            let company = UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8
            guard company == manufacturer else { return false }
        }
        if let rssiMin, device.rssi < rssiMin { return false }
        return true
    }
}

/// The device a command names with its targeting options (`-i`, `-n`, `-S`,
/// `-m`, `-R`, `-p`).
struct DeviceTarget: Equatable {
    var filter = DeviceFilter()
    /// `-p`; nil when the option is absent.
    var pick: PickStrategy?

    /// Parse the targeting options in `args`. `optionsWithValue` lists the
    /// command's options that take a value, so their values are never read
    /// as targeting options. Throws a message for the user when a targeting
    /// option has no value or a value it cannot use, or when an option other
    /// than `-S` is given twice.
    static func parse(_ args: [String], optionsWithValue: Set<String>) throws -> DeviceTarget {
        let options = CommandRouter.scanOptions(args, optionsWithValue: optionsWithValue)
        func values(_ short: String, _ long: String) throws -> [String] {
            try options.filter { $0.name == short || $0.name == long }.map { option in
                guard let value = option.value else { throw InvalidArgument("\(option.name) needs a value") }
                return value
            }
        }
        func value(_ short: String, _ long: String) throws -> String? {
            let all = try values(short, long)
            guard all.count <= 1 else { throw InvalidArgument("\(long) is given more than once") }
            return all.first
        }

        var target = DeviceTarget()
        target.filter.id = try value("-i", "--id")
        target.filter.name = try value("-n", "--name")
        target.filter.services = try values("-S", "--service").map { text in
            guard let uuid = BLENames.canonicalUUID(text) else {
                throw InvalidArgument("invalid service UUID '\(text)' (use 4 or 8 hex digits or a 128-bit UUID)")
            }
            return uuid
        }
        if let text = try value("-m", "--manufacturer") {
            guard let id = UInt16(text) else {
                throw InvalidArgument("invalid manufacturer ID '\(text)' (use a decimal company identifier, 0 to 65535)")
            }
            target.filter.manufacturer = id
        }
        if let text = try value("-R", "--rssi-min") {
            guard let rssi = Int(text) else {
                throw InvalidArgument("invalid RSSI '\(text)' (use a whole number of dBm, e.g. -70)")
            }
            target.filter.rssiMin = rssi
        }
        if let text = try value("-p", "--pick") {
            guard let pick = PickStrategy(rawValue: text) else {
                throw InvalidArgument("invalid pick strategy '\(text)' (use strongest, first or only)")
            }
            target.pick = pick
        }
        return target
    }

    /// Whether `connected` is the device this target names. `-i` compares
    /// identifiers. The other filters are checked against the device's
    /// record from the last scan, and nothing matches when that record is
    /// unknown. A target that names no device accepts any connected device.
    func accepts(_ connected: ConnectedDevice) -> Bool {
        if let id = filter.id { return id.caseInsensitiveCompare(connected.id) == .orderedSame }
        if filter.isEmpty { return true }
        guard let advertisement = connected.advertisement,
              advertisement.identifier.caseInsensitiveCompare(connected.id) == .orderedSame else {
            return false
        }
        return filter.matches(advertisement)
    }
}

/// The connected device as device selection sees it.
struct ConnectedDevice {
    let id: String
    /// The device's record from the last scan; nil when that scan did not see it.
    let advertisement: DiscoveredDevice?
}

/// Why a `-i` value (or MCP `device_id`) does not stand for one identifier.
enum IdentifierFailure: Error, Equatable {
    /// The value is a fragment of several known identifiers, listed in order.
    case ambiguous([String])
    /// The value is hex digits and hyphens, but no known identifier contains it.
    case notFound
    /// The value is neither a UUID nor hex digits and hyphens.
    case notAnIdentifier
}

extension DeviceTarget {
    /// The full identifier `input` stands for among the `known` identifiers.
    /// Only identifiers are compared, never advertised names, so a nearby
    /// device cannot capture the value by advertising it as its name. A
    /// value that parses as a UUID names exactly that identifier, whether or
    /// not it is known, and so do its 32 hex digits without hyphens.
    /// Otherwise its hex digits, hyphens removed and without regard to case,
    /// must occur in exactly one known identifier with its hyphens removed.
    static func resolveIdentifier(_ input: String, among known: [String]) -> Result<String, IdentifierFailure> {
        if let uuid = UUID(uuidString: input) {
            return .success(known.first { UUID(uuidString: $0) == uuid } ?? uuid.uuidString)
        }
        let fragment = input.replacingOccurrences(of: "-", with: "").uppercased()
        guard !fragment.isEmpty, fragment.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return .failure(.notAnIdentifier)
        }
        if fragment.count == 32 {
            let digits = Array(fragment)
            let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(digits[$0]) }
            return resolveIdentifier(groups.joined(separator: "-"), among: known)
        }
        let matches = known.filter { $0.replacingOccurrences(of: "-", with: "").uppercased().contains(fragment) }
        switch matches.count {
        case 0: return .failure(.notFound)
        case 1: return .success(matches[0])
        default: return .failure(.ambiguous(matches))
        }
    }
}

/// Auto-connect replacing the connected device `from` with `to`. It is
/// reported once `from` is disconnected, which ends every subscription on
/// it, whether or not the connect to `to` then succeeded.
struct DeviceSwitch: Equatable, Codable {
    let from: String
    let to: String

    /// The switch from `connected` to the device `id`; nil when nothing is
    /// connected or `id` is the connected device.
    init?(replacing connected: ConnectedDevice?, with id: String) {
        guard let connected, connected.id.caseInsensitiveCompare(id) != .orderedSame else { return nil }
        from = connected.id
        to = id
    }

    /// The line for stderr.
    var notice: String { "disconnected \(from) to connect to \(to)" }
}

/// A command argument that cannot be used, with the message for the user.
struct InvalidArgument: Error, LocalizedError, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

/// What auto-connect does for a command's target. Every step but
/// `useConnected` replaces a connected device; the caller disconnects it
/// only once the new device is known, never before.
enum AutoConnectPlan: Equatable {
    /// The connected device is the target; use it.
    case useConnected
    /// Connect to this full identifier.
    case connect(String)
    /// Scan for devices that match the filter and connect to the one the strategy picks.
    case scan(DeviceFilter, PickStrategy)
    /// Nothing is connected and nothing names a device.
    case noTarget
    /// `-i` (the value given) does not stand for one identifier.
    case unresolvedIdentifier(String, IdentifierFailure)

    /// `connected` is nil when nothing is connected. `scanned` are the
    /// identifiers of the last scan; `-i` resolves among them and the
    /// connected device's (`DeviceTarget.resolveIdentifier`). `defaultFilter` is the
    /// filter to scan with when the target names no device (`nus` looks for
    /// the Nordic UART Service); it never replaces a connected device. With
    /// `reconnect` (the `connect` command), a target that names the
    /// connected device connects to it afresh by its identifier, without a
    /// scan, since a connected device usually stops advertising.
    static func make(target: DeviceTarget, defaultFilter: DeviceFilter = DeviceFilter(),
                     connected: ConnectedDevice?, scanned: [String], reconnect: Bool = false) -> AutoConnectPlan {
        var target = target
        if let input = target.filter.id {
            var known = scanned
            if let connected, !known.contains(where: { $0.caseInsensitiveCompare(connected.id) == .orderedSame }) {
                known.append(connected.id)
            }
            switch DeviceTarget.resolveIdentifier(input, among: known) {
            case .success(let id): target.filter.id = id
            case .failure(let failure): return .unresolvedIdentifier(input, failure)
            }
        }
        if let connected, target.accepts(connected) {
            return reconnect && !target.filter.isEmpty ? .connect(connected.id) : .useConnected
        }
        if let id = target.filter.id { return .connect(id) }
        let filter = target.filter.isEmpty ? defaultFilter : target.filter
        guard !filter.isEmpty else { return .noTarget }
        return .scan(filter, target.pick ?? .strongest)
    }
}

enum PickOutcome: Equatable {
    case picked(DiscoveredDevice)
    case noDevices
    /// `--pick only` found more than one device.
    case several([DiscoveredDevice])
}

extension PickStrategy {
    /// Pick one device from `candidates`, which are in the order the scan
    /// first saw them. `strongest` takes the highest RSSI (the earlier seen
    /// on a tie), `first` the first seen, `only` the single candidate.
    func choose(from candidates: [DiscoveredDevice]) -> PickOutcome {
        guard let first = candidates.first else { return .noDevices }
        switch self {
        case .first:
            return .picked(first)
        case .strongest:
            return .picked(candidates.dropFirst().reduce(first) { $1.rssi > $0.rssi ? $1 : $0 })
        case .only:
            return candidates.count == 1 ? .picked(first) : .several(candidates)
        }
    }
}

/// The devices one scan has seen, merged per identifier, in the order first
/// seen. A device keeps the latest RSSI and the latest name, service list
/// and manufacturer data it advertised, because any of them can be missing
/// from a later advertisement. A list is replaced, never accumulated, so a
/// device that keeps changing its advertisement cannot grow its record.
struct ScanResults {
    private(set) var devices: [DiscoveredDevice] = []
    private var positions: [String: Int] = [:]

    /// Merge `device` into the results and return its merged record.
    @discardableResult
    mutating func add(_ device: DiscoveredDevice) -> DiscoveredDevice {
        guard let position = positions[device.identifier] else {
            positions[device.identifier] = devices.count
            devices.append(device)
            return device
        }
        let old = devices[position]
        let merged = DiscoveredDevice(
            identifier: device.identifier,
            name: device.name ?? old.name,
            rssi: device.rssi,
            serviceUUIDs: device.serviceUUIDs.isEmpty ? old.serviceUUIDs : device.serviceUUIDs,
            manufacturerData: device.manufacturerData ?? old.manufacturerData)
        devices[position] = merged
        return merged
    }

    /// The devices that match `filter`, in the order first seen.
    func matching(_ filter: DeviceFilter) -> [DiscoveredDevice] {
        devices.filter(filter.matches)
    }
}

extension Array where Element == DiscoveredDevice {
    /// Strongest signal first, the display order of scan tables.
    var byRSSI: [DiscoveredDevice] { sorted { $0.rssi > $1.rssi } }
}
