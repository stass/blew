import ArgumentParser
import Foundation
import BLEManager

struct DisconnectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disconnect",
        abstract: "Disconnect from the current BLE device"
    )

    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let router = CommandRouter(globals: globals)
        let code = router.runDisconnect([])
        if code != 0 { throw BlewExitCode(code) }
    }
}
