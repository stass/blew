import ArgumentParser
import Foundation
import BLEManager

struct NUSCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nus",
        abstract: "Bridge to a device's Nordic UART Service",
        discussion: """
            Connects like 'connect' (with no device options, to the strongest device \
            advertising NUS), subscribes to TX and writes to RX in MTU-sized chunks. \
            Bytes pass unchanged in both directions.

            By default standard input goes to the device and the device's output to \
            standard output, until end of input plus --duration seconds. --send or \
            --file send fixed bytes instead; with --expect the exit status says whether \
            the expected text arrived. --pty bridges a pseudo-terminal for screen, cu \
            or picocom; --listen bridges one TCP client at a time.
            """
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Option(name: [.customShort("s"), .long], help: ArgumentHelp(
        "Send this text instead of standard input (repeatable). Escapes \\n \\r \\t \\0 \\\\ \\xHH are decoded; no newline is added.",
        valueName: "text"))
    var send: [String] = []

    @Option(name: .customLong("file"), help: ArgumentHelp("Send the contents of this file instead of standard input.", valueName: "path"))
    var file: String?

    @Option(name: [.customShort("e"), .long], help: ArgumentHelp(
        "Succeed once this text arrives (same escapes); fail with exit code 4 if it does not.", valueName: "text"))
    var expect: String?

    @Option(name: [.customShort("d"), .long], help: ArgumentHelp(
        "Seconds to keep listening after the input ends (default 1); with --expect, the deadline for it (default 5).",
        valueName: "sec"))
    var duration: Double?

    @Flag(name: .customLong("pty"), help: "Bridge a pseudo-terminal instead of standard input/output; its path is printed on standard error.")
    var pty: Bool = false

    @Option(name: [.customShort("l"), .long], help: ArgumentHelp("Bridge one TCP client at a time on this port.", valueName: "port"))
    var listen: UInt16?

    @Option(name: .customLong("bind"), help: ArgumentHelp("Address for --listen (default 127.0.0.1). There is no authentication.", valueName: "addr"))
    var bind: String?

    @Flag(name: .customLong("reconnect"), help: "Reconnect after the device disconnects, keeping the local endpoint open.")
    var reconnect: Bool = false

    @Flag(name: [.customShort("r"), .customLong("with-response")], help: "Write with response.")
    var withResponse: Bool = false

    @Flag(name: [.customShort("w"), .customLong("without-response")], help: "Write without response.")
    var withoutResponse: Bool = false

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        let result: CommandResult
        do {
            let options = try NUSOptions.make(
                targeting: targeting.toArgs(), sends: send, file: file, expect: expect, duration: duration,
                pty: pty, listen: listen, bind: bind, reconnect: reconnect,
                withResponse: withResponse, withoutResponse: withoutResponse, stdinAvailable: true)
            result = router.runNUS(options, emit: { router.renderer.render($0) })
        } catch {
            result = CommandResult(failing: error)
        }
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}
