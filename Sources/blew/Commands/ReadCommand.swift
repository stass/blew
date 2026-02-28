import ArgumentParser
import Foundation
import BLEManager

struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read a characteristic value"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Option(name: [.customShort("f"), .long], help: "Format: hex, utf8, base64, uint8, uint16le, uint32le, float32le, raw.")
    var format: String = "hex"

    @Argument(help: "Characteristic UUID to read.")
    var char: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = targeting.toArgs()
        args += ["-f", format, char]
        let code = router.runRead(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}
