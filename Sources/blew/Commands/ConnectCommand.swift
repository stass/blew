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
        let code = router.runConnect(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}
