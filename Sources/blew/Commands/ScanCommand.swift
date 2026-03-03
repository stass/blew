import ArgumentParser
import Foundation
import BLEManager

struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan for BLE devices"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Flag(name: [.customShort("w"), .long], help: "Continuously scan and show a live-updating device list (Ctrl-C to stop).")
    var watch: Bool = false

    mutating func run() throws {
        let globals = GlobalOptions.current!
        let router = CommandRouter(globals: globals)
        var args = targeting.toArgs()
        if watch { args.append("--watch") }
        let result = router.runScan(args)
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}
