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

            macOS GAP name limitation: the advertising local name (-n) appears in raw ADV
            data but iOS devices show the Mac's hostname (GAP name) in their scan list.
            """,
        subcommands: [
            AdvCommand.self,
            CloneCommand.self,
        ]
    )
}

struct AdvCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adv",
        abstract: "Advertise a virtual BLE device and host a GATT server"
    )

    @Option(name: [.short, .long], help: "Advertised device name. Defaults to 'blew' or config name.")
    var name: String?

    @Option(name: [.customShort("S"), .long], help: "Service UUID to advertise (repeatable).")
    var service: [String] = []

    @Option(name: [.customShort("c"), .customLong("config")], help: "JSON config file defining services and characteristics.")
    var config: String?

    mutating func run() throws {
        let globals = GlobalOptions.current!
        let router = CommandRouter(globals: globals)
        var args: [String] = []
        if let n = name { args += ["-n", n] }
        for s in service { args += ["-S", s] }
        if let c = config { args += ["-c", c] }
        let code = router.runPeriphAdv(args)
        cleanupBeforeExit()
        if code != 0 { throw BlewExitCode(code) }
    }
}

struct CloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Clone a real device's GATT structure and re-advertise it"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Option(name: [.customShort("o"), .customLong("save")], help: "Save cloned GATT structure to a JSON config file.")
    var save: String?

    mutating func run() throws {
        let globals = GlobalOptions.current!
        let router = CommandRouter(globals: globals)
        var args = targeting.toArgs()
        if let s = save { args += ["-o", s] }
        let code = router.runPeriphClone(args)
        cleanupBeforeExit()
        if code != 0 { throw BlewExitCode(code) }
    }
}
