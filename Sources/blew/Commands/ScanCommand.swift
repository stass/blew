import ArgumentParser
import Foundation
import BLEManager

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan for BLE devices",
        discussion: "Device targeting and output options are global options; pass them before the subcommand name (see blew --help)."
    )

    mutating func run() throws {
        let globals = GlobalOptions.current!
        let scanTimeout = globals.timeout ?? 5.0
        let router = CommandRouter(globals: globals)
        var args: [String] = ["-t", "\(scanTimeout)"]
        if let name = globals.name { args += ["-n", name] }
        if let rssi = globals.rssiMin { args += ["-r", "\(rssi)"] }
        let code = router.runScan(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}
