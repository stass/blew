import ArgumentParser
import Foundation

struct GlobalOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "Increase verbosity (repeatable, e.g. -vv).")
    var verbose: Int

    @Option(name: [.short, .long], help: "Timeout in seconds for BLE operations.")
    var timeout: Double?

    @Option(name: [.short, .long], help: "Output format: text or kv.")
    var out: OutputFormat = .text

    // Device targeting
    @Option(name: [.short, .customLong("id")], help: "Explicit device identifier.")
    var id: String?

    @Option(name: [.short, .long], help: "Filter by device name substring.")
    var name: String?

    @Option(name: [.customShort("S"), .long], help: "Filter by advertised service UUID (repeatable).")
    var service: [String] = []

    @Option(name: [.short, .long], help: "Filter by manufacturer ID.")
    var manufacturer: Int?

    @Option(name: [.customShort("r"), .customLong("rssi-min")], help: "Minimum RSSI in dBm.")
    var rssiMin: Int?

    @Option(name: [.short, .long], help: "Device pick strategy: strongest, first, or only.")
    var pick: PickStrategy = .strongest

    // Script execution
    @Option(name: [.customShort("x"), .customLong("exec")], help: "Execute semicolon-separated commands.")
    var exec: String?

    @Flag(name: [.customShort("k"), .customLong("keep-going")], help: "Continue after command errors in --exec.")
    var keepGoing: Bool = false

    @Flag(name: .customLong("dry-run"), help: "Print parsed steps without executing.")
    var dryRun: Bool = false
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
