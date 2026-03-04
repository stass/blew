import ArgumentParser
import Foundation
import BLEManager

/// Set by the SIGINT handler when a command is in flight; cleared by the polling loop.
nonisolated(unsafe) var interruptRequested = false
/// Set to true while a command's polling loop is active; controls SIGINT disposition.
nonisolated(unsafe) var commandIsRunning = false

@main
struct Blew: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "blew",
        abstract: "macOS BLE CLI workbench",
        discussion: "Global options must be placed before the subcommand name.",
        version: "0.2.0",
        subcommands: [
            ScanCommand.self,
            ConnectCommand.self,
            GATTCommand.self,
            ReadCommand.self,
            WriteCommand.self,
            SubCommand.self,
            PeriphCommand.self,
            ExecCommand.self,
            MCPCommand.self,
        ]
    )

    @OptionGroup var globals: GlobalOptions

    mutating func validate() throws {
        GlobalOptions.current = globals
    }

    mutating func run() async throws {
        installSignalHandlers()
        let repl = REPL(globals: globals)
        repl.run()
        cleanupBeforeExit()
    }
}

/// Best-effort disconnect and stop advertising on process exit.
func cleanupBeforeExit() {
    if BLEPeripheral.shared.isAdvertising() {
        BLEPeripheral.shared.stopAdvertising()
    }

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
        if commandIsRunning {
            interruptRequested = true
        } else {
            cleanupBeforeExit()
            _exit(130)
        }
    }
}
