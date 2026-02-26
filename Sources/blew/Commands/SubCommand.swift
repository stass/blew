import ArgumentParser
import Foundation
import BLEManager

struct SubCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sub",
        abstract: "Subscribe to notifications/indications",
        discussion: "Device targeting and output options are global options; pass them before the subcommand name (see blew --help)."
    )

    @Option(name: [.customShort("c"), .long], help: "Characteristic UUID to subscribe.")
    var char: String

    @Option(name: [.customShort("F"), .long], help: "Output format: hex, utf8, base64, uint8, uint16le, uint32le, float32le.")
    var format: String = "hex"

    @Option(name: [.customShort("D"), .long], help: "Stop after this many seconds.")
    var duration: Double?

    @Option(name: [.customShort("C"), .long], help: "Stop after this many notifications.")
    var count: Int?

    @Flag(name: .customLong("notify"), help: "Force notify mode.")
    var forceNotify: Bool = false

    @Flag(name: .customLong("indicate"), help: "Force indicate mode.")
    var forceIndicate: Bool = false

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = ["-c", char, "-F", format]
        if let d = duration { args += ["-D", "\(d)"] }
        if let c = count { args += ["-C", "\(c)"] }
        let code = router.runSub(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}
