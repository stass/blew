import ArgumentParser
import Foundation
import os
import BLEManager

@main
struct Blew: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "blew",
        abstract: "macOS BLE CLI workbench",
        discussion: "Global options must be placed before the subcommand name.",
        version: "0.2.0",
        subcommands: Blew.subcommandList
    )

    /// The `mcp` subcommand is only available when built with a toolchain that
    /// supports the MCP swift-sdk (Swift 6.1+); see Package.swift.
    static var subcommandList: [ParsableCommand.Type] {
        var commands: [ParsableCommand.Type] = [
            ScanCommand.self,
            ConnectCommand.self,
            GATTCommand.self,
            ReadCommand.self,
            WriteCommand.self,
            SubCommand.self,
            NUSCommand.self,
            PeriphCommand.self,
            ExecCommand.self,
        ]
        #if MCP_ENABLED
        commands.append(MCPCommand.self)
        #endif
        return commands
    }

    @OptionGroup var globals: GlobalOptions

    /// ArgumentParser's own main reports any thrown error with exit code 1
    /// and prints "Error: exit code N". Commands have already reported their
    /// errors when they throw BlewExitCode, so exit with its code quietly.
    static func main() async {
        // Piped or redirected output goes out a line at a time, so a reader
        // sees each record as it is printed (`blew -o kv sub ... >> log`).
        if isatty(STDOUT_FILENO) == 0 {
            setvbuf(stdout, nil, _IOLBF, 0)
        }
        ProcessSignals.shared.install()
        do {
            var command = try parseAsRoot()
            // Every command runs inside one span, so a Ctrl-C seen by any of
            // its waits stops the rest of it. The REPL and the MCP server
            // open a span per command or tool call instead.
            let outerSpan = Self.opensOuterSpan(for: command)
            if outerSpan { ProcessSignals.shared.commandStarted() }
            defer { if outerSpan { ProcessSignals.shared.commandFinished() } }
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let code as BlewExitCode {
            Foundation.exit(code.code)
        } catch {
            exit(withError: error)
        }
    }

    mutating func validate() throws {
        GlobalOptions.current = globals
    }

    mutating func run() async throws {
        let repl = REPL(globals: globals)
        defer { cleanupBeforeExit() }
        try repl.run()
    }
}

/// Whether `cleanupBeforeExit` has run; it runs once, on the main thread
/// or on the signal queue, whichever exits first.
private let cleanupOnce = OSAllocatedUnfairLock(initialState: false)

/// Best-effort disconnect and stop advertising on process exit.
func cleanupBeforeExit() {
    let alreadyRan = cleanupOnce.withLock { ran in
        defer { ran = true }
        return ran
    }
    if alreadyRan { return }
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

/// A command that opens its own signal spans, one per command it runs (the
/// REPL) or per tool call (the MCP server), instead of running inside one
/// span for its whole life.
protocol OpensOwnCommandSpans {}

extension Blew: OpensOwnCommandSpans {}
#if MCP_ENABLED
extension MCPCommand: OpensOwnCommandSpans {}
#endif

extension Blew {
    /// Whether `main` runs `command` inside one signal span.
    static func opensOuterSpan(for command: ParsableCommand) -> Bool {
        !(command is OpensOwnCommandSpans)
    }
}
