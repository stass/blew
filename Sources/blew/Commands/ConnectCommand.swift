import ArgumentParser
import Foundation
import BLEManager

struct ConnectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Connect to a BLE device"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Argument(help: "Device identifier to connect to (overrides --id).")
    var deviceId: String?

    mutating func run() throws {
        let globals = GlobalOptions.current!
        let router = CommandRouter(globals: globals)
        var args = targeting.toArgs()
        if let id = deviceId { args.append(id) }
        let result = router.runConnect(args)
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}
