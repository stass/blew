import ArgumentParser
import Foundation
import BLEManager

struct ConnectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect",
        abstract: "Connect to a BLE device"
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Device identifier to connect to.")
    var deviceId: String?

    mutating func run() throws {
        let router = CommandRouter(globals: globals)
        var args: [String] = []
        if let id = deviceId ?? globals.id {
            args.append(id)
        }
        let code = router.runConnect(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}
