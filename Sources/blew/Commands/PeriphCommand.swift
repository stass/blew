import ArgumentParser
import Foundation
import BLEManager

struct PeriphCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "periph",
        abstract: "Peripheral (GATT server) mode — advertise and serve a virtual BLE device",
        discussion: """
            CoreBluetooth peripheral limitations:
              - Only local name and service UUIDs can be advertised (no manufacturer data).
              - ADV interval, TX power, and connection parameters are OS-controlled.
              - Clone mode replicates GATT structure and initial values, not raw ADV bytes.
            """,
        subcommands: [AdvCommand.self, CloneCommand.self]
    )
}

// MARK: - periph adv

struct AdvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adv",
        abstract: "Advertise a virtual BLE device and host a GATT server",
        discussion: """
            Runs until interrupted (Ctrl-C). Events (reads, writes, subscriptions) are
            logged to stdout.

            Examples:
              blew periph adv -n "My Device" -S 180F
              blew periph adv -n "My Device" -S 180F -S 180A
              blew periph adv --config device.json
            """
    )

    @Option(name: [.short, .long], help: "Advertised device name (default: blew).")
    var name: String?

    @Option(name: [.customShort("S"), .long], help: "Service UUID to advertise (repeatable).")
    var service: [String] = []

    @Option(name: [.customShort("c"), .customLong("config")], help: "Path to a JSON config file defining services and characteristics.")
    var config: String?

    mutating func run() throws {
        let globals = GlobalOptions.current!
        let router = CommandRouter(globals: globals)
        var args: [String] = []
        if let name = name { args += ["-n", name] }
        for uuid in service { args += ["-S", uuid] }
        if let config = config { args += ["--config", config] }
        let code = router.runPeriphAdv(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}

// MARK: - periph clone

struct CloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Clone a real device's GATT structure and re-advertise as a virtual device",
        discussion: """
            Connects to the target device, snapshots its full GATT tree and all readable
            characteristic values, disconnects, then starts advertising as a clone.

            Use global device-targeting options (--id, --name, --service) to specify the
            target device.

            Note: only service UUIDs and local name are cloned in the advertisement.
            Manufacturer data and other ADV payload fields cannot be replicated via
            CoreBluetooth's peripheral API.
            """
    )

    @Option(name: [.customShort("o"), .customLong("save")], help: "Save the cloned GATT structure to a JSON config file for later reuse.")
    var save: String?

    mutating func run() throws {
        let globals = GlobalOptions.current!
        let router = CommandRouter(globals: globals)
        var args: [String] = []
        if let save = save { args += ["--save", save] }
        let code = router.runPeriphClone(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}
