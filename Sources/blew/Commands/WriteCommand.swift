import ArgumentParser
import Foundation
import BLEManager

struct WriteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Write to a characteristic"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Option(name: [.customShort("f"), .long], help: "Data format: hex, utf8, base64, uint8, uint16le, uint32le, float32le.")
    var format: String = "hex"

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
        args += ["-f", format, char, data]
        if withResponse { args.append("-r") }
        if withoutResponse { args.append("-w") }
        let result = router.runWrite(args)
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}
