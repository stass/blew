import ArgumentParser
import Foundation
import BLEManager

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show connection status"
    )

    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let router = CommandRouter(globals: globals)
        let code = router.runStatus([])
        if code != 0 { throw BlewExitCode(code) }
    }
}
