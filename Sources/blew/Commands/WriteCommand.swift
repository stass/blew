import ArgumentParser
import Foundation
import BLEManager

struct WriteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Write to a characteristic",
        discussion: "Device targeting and output options are global options; pass them before the subcommand name (see blew --help)."
    )

    @Option(name: [.customShort("c"), .long], help: "Characteristic UUID to write.")
    var char: String

    @Option(name: [.customShort("d"), .long], help: "Data to write.")
    var data: String

    @Option(name: [.customShort("F"), .long], help: "Data format: hex, utf8, base64, uint8, uint16le, uint32le, float32le.")
    var format: String = "hex"

    @Flag(name: [.customShort("R"), .customLong("with-response")], help: "Write with response.")
    var withResponse: Bool = false

    @Flag(name: [.customShort("W"), .customLong("without-response")], help: "Write without response.")
    var withoutResponse: Bool = false

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = ["-c", char, "-d", data, "-F", format]
        if withResponse { args.append("-R") }
        if withoutResponse { args.append("-W") }
        let code = router.runWrite(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}
