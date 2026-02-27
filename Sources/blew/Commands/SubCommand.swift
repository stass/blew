import ArgumentParser
import Foundation
import BLEManager

struct SubCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sub",
        abstract: "Subscribe to notifications/indications",
        discussion: "Device targeting and output options are global options; pass them before the subcommand name (see blew --help)."
    )

    @Option(name: [.customShort("f"), .long], help: "Output format: hex, utf8, base64, uint8, uint16le, uint32le, float32le.")
    var format: String = "hex"

    @Option(name: [.customShort("d"), .long], help: "Stop after this many seconds.")
    var duration: Double?

    @Option(name: [.customShort("c"), .long], help: "Stop after this many notifications.")
    var count: Int?

    @Flag(name: .customLong("notify"), help: "Force notify mode.")
    var forceNotify: Bool = false

    @Flag(name: .customLong("indicate"), help: "Force indicate mode.")
    var forceIndicate: Bool = false

    @Argument(help: "Characteristic UUID to subscribe.")
    var char: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = ["-f", format, char]
        if let d = duration { args += ["-d", "\(d)"] }
        if let c = count { args += ["-c", "\(c)"] }
        let code = router.runSub(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}
