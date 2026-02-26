import ArgumentParser
import Foundation
import BLEManager

struct ReadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read a characteristic value"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: [.customShort("c"), .long], help: "Characteristic UUID to read.")
    var char: String

    @Option(name: [.customShort("F"), .long], help: "Format: hex, utf8, base64, uint8, uint16le, uint32le, float32le, raw.")
    var format: String = "hex"

    mutating func run() throws {
        let router = CommandRouter(globals: globals)
        let code = router.runRead(["-c", char, "-F", format])
        if code != 0 { throw BlewExitCode(code) }
    }
}
