import ArgumentParser
import Foundation
import BLEManager

struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read a characteristic value"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Option(name: [.customShort("f"), .long], help: "Value format.")
    var format: ValueFormat = .hex

    @Argument(help: "Characteristic UUID to read.")
    var char: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = targeting.toArgs()
        args += ["-f", format.rawValue, "--", char]
        let result = router.runRead(args)
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}
