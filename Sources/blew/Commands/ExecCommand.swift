import ArgumentParser
import Foundation
import BLEManager

struct ExecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Execute a semicolon-separated sequence of commands",
        discussion: """
            Runs commands in a single process, sharing one connection lifecycle.
            Commands are parsed identically to the REPL.

            Examples:
              blew exec "connect -n Thingy; gatt tree; read -f uint8 2A19"
              blew exec -k "read fff1; read fff9"
              blew exec --dry-run "connect -n Thingy; gatt tree"
            """
    )

    @Argument(help: "Semicolon-separated commands to execute.")
    var script: String

    @Flag(name: [.customShort("k"), .customLong("keep-going")], help: "Continue after a command error; exit with the first non-zero code seen.")
    var keepGoing: Bool = false

    @Flag(name: .customLong("dry-run"), help: "Print parsed steps without executing them.")
    var dryRun: Bool = false

    mutating func run() throws {
        let globals = GlobalOptions.current!
        let router = CommandRouter(globals: globals, isInteractiveMode: true)
        let code = router.executeScript(script, keepGoing: keepGoing, dryRun: dryRun)
        cleanupBeforeExit()
        if code != 0 { throw BlewExitCode(code) }
    }
}
