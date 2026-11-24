import ArgumentParser
import Foundation
import BLEManager

struct WriteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Write to a characteristic"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Option(name: [.customShort("f"), .long], help: "Value format.")
    var format: ValueFormat = .hex

    @Flag(name: [.customShort("r"), .customLong("with-response")], help: "Write with response.")
    var withResponse: Bool = false

    @Flag(name: [.customShort("w"), .customLong("without-response")], help: "Write without response.")
    var withoutResponse: Bool = false

    @Argument(help: "Characteristic UUID to write.")
    var char: String

    @Argument(help: "Data to write.")
    var data: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = targeting.toArgs()
        args += ["-f", format.rawValue]
        if withResponse { args.append("-r") }
        if withoutResponse { args.append("-w") }
        // `--` keeps a value that starts with `-` (`-- -1.5`) a value.
        args += ["--", char, data]
        let result = router.runWrite(args)
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}
