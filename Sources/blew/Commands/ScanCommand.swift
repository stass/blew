import ArgumentParser
import Foundation
import BLEManager

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan for BLE devices",
        discussion: "Device targeting and output options are global options; pass them before the subcommand name (see blew --help)."
    )

    @Flag(name: [.customShort("w"), .long], help: "Continuously scan and show a live-updating device list (Ctrl-C to stop).")
    var watch: Bool = false

    mutating func run() throws {
        let globals = GlobalOptions.current!
        let router = CommandRouter(globals: globals)
        var args: [String] = []
        if let timeout = globals.timeout { args += ["-t", "\(timeout)"] }
        if let name = globals.name { args += ["-n", name] }
        if let rssi = globals.rssiMin { args += ["-r", "\(rssi)"] }
        if watch { args.append("--watch") }
        let code = router.runScan(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}
