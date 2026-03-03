import ArgumentParser
import Foundation
import BLEManager

struct SubCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sub",
        abstract: "Subscribe to notifications/indications"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Option(name: [.customShort("f"), .long], help: "Output format: hex, utf8, base64, uint8, uint16le, uint32le, float32le.")
    var format: String = "hex"

    @Option(name: [.customShort("d"), .long], help: "Stop after this many seconds.")
    var duration: Double?

    @Option(name: [.customShort("c"), .long], help: "Stop after this many notifications.")
    var count: Int?

    @Argument(help: "Characteristic UUID to subscribe.")
    var char: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = targeting.toArgs()
        args += ["-f", format, char]
        if let d = duration { args += ["-d", "\(d)"] }
        if let c = count { args += ["-c", "\(c)"] }
        let result = router.runSub(args)
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}
