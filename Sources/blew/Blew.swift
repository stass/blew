import ArgumentParser
import Foundation
import BLEManager

@main
struct Blew: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "blew",
        abstract: "macOS BLE CLI workbench",
        discussion: "Global options must be placed before the subcommand name.",
        version: "0.1.0",
        subcommands: [
            ScanCommand.self,
            ConnectCommand.self,
            GATTCommand.self,
            ReadCommand.self,
            WriteCommand.self,
            SubCommand.self,
        ]
    )

    @OptionGroup var globals: GlobalOptions

    mutating func validate() throws {
        GlobalOptions.current = globals
    }

    mutating func run() throws {
        installSignalHandlers()

        if let execString = globals.exec {
            let router = CommandRouter(globals: globals)
            let code = router.executeScript(execString)
            cleanupBeforeExit()
            if code != 0 {
                throw BlewExitCode(code)
            }
        } else {
            let repl = REPL(globals: globals)
            repl.run()
            cleanupBeforeExit()
        }
    }
}

/// Best-effort disconnect on process exit.
private func cleanupBeforeExit() {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let status = await BLECentral.shared.status()
        if status.isConnected {
            try? await BLECentral.shared.disconnect()
        }
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 2.0)
}

private func installSignalHandlers() {
    signal(SIGTERM) { _ in
        cleanupBeforeExit()
        _exit(0)
    }
    signal(SIGINT) { _ in
        cleanupBeforeExit()
        _exit(130)
    }
}
