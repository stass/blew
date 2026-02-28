import ArgumentParser
import Foundation

struct GlobalOptions: ParsableArguments {
    nonisolated(unsafe) static var current: GlobalOptions!

    @Flag(name: [.short, .long], help: "Increase verbosity (repeatable, e.g. -vv).")
    var verbose: Int

    @Option(name: [.short, .long], help: "Timeout in seconds for BLE operations.")
    var timeout: Double?

    @Option(name: [.short, .long], help: "Output format: text or kv.")
    var out: OutputFormat = .text
}

/// Device targeting options shared across all commands that need to locate a device.
struct DeviceTargetingOptions: ParsableArguments {
    @Option(name: [.customShort("i"), .customLong("id")], help: "Explicit device identifier.")
    var id: String?

    @Option(name: [.short, .long], help: "Filter by device name substring.")
    var name: String?

    @Option(name: [.customShort("S"), .long], help: "Filter by advertised service UUID (repeatable).")
    var service: [String] = []

    @Option(name: [.short, .long], help: "Filter by manufacturer ID.")
    var manufacturer: Int?

    @Option(name: [.customShort("R"), .customLong("rssi-min")], help: "Minimum RSSI in dBm.")
    var rssiMin: Int?

    @Option(name: [.short, .long], help: "Device pick strategy: strongest, first, or only.")
    var pick: PickStrategy = .strongest

    /// Serialize non-nil targeting values into a flat string array suitable for passing to CommandRouter run* methods.
    func toArgs() -> [String] {
        var args: [String] = []
        if let id = id { args += ["-i", id] }
        if let name = name { args += ["-n", name] }
        for uuid in service { args += ["-S", uuid] }
        if let m = manufacturer { args += ["-m", "\(m)"] }
        if let r = rssiMin { args += ["-R", "\(r)"] }
        if pick != .strongest { args += ["-p", pick.rawValue] }
        return args
    }
}

enum OutputFormat: String, ExpressibleByArgument, Sendable {
    case text
    case kv
}

enum PickStrategy: String, ExpressibleByArgument, Sendable {
    case strongest
    case first
    case only
}
