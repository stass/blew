import ArgumentParser
import Foundation
import BLEManager

struct SubCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sub",
        abstract: "Subscribe to notifications/indications"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Option(name: [.customShort("f"), .long], help: "Value format.")
    var format: ValueFormat = .hex

    @Option(name: [.customShort("d"), .long], help: "Stop after this many seconds.")
    var duration: Double?

    @Option(name: [.customShort("c"), .long], help: "Stop after this many notifications.")
    var count: Int?

    @Argument(help: "Characteristic UUID to subscribe.")
    var char: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = targeting.toArgs()
        args += ["-f", format.rawValue]
        if let d = duration { args += ["-d", "\(d)"] }
        if let c = count { args += ["-c", "\(c)"] }
        args += ["--", char]
        let result = router.runSub(args, emit: { router.renderer.render($0) })
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}
