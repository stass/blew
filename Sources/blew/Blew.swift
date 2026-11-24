import ArgumentParser
import Foundation
import os
import BLEManager

@main
struct Blew: AsyncParsableCommand {
    /// The release version, reported by `--version` and the MCP handshake.
    static let version = "0.3.0"

    static let configuration = CommandConfiguration(
        commandName: "blew",
        abstract: "macOS BLE CLI workbench",
        discussion: "Global options must be placed before the subcommand name.",
        version: Blew.version,
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

    /// Every mode leaves through here: the command's code, then the one
    /// ordinary exit (`exitOrdinarily`), which a signal that began the exit
    /// first overrides with its own code.
    static func main() async {
        StandardOutput.lineBufferUnlessTerminal()
        ProcessSignals.shared.install()
        exitOrdinarily(await runCommandLine())
    }

    /// Parse the command line, run its command and return the exit code,
    /// with any error already reported.
    static func runCommandLine() async -> Int32 {
        var command: ParsableCommand
        do {
            command = try parseAsRoot()
        } catch {
            return report(error)
        }
        // Every command runs inside one span, so a Ctrl-C seen by any of
        // its waits stops the rest of it. The REPL and the MCP server open a
        // span per command or tool call instead.
        let outerSpan = Self.opensOuterSpan(for: command)
        if outerSpan { ProcessSignals.shared.commandStarted() }
        var code = BlewExitCode.success.code
        do {
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            code = report(error)
        }
        guard outerSpan else { return code }
        let stopRequested = ProcessSignals.shared.commandFinished()
        return SignalPolicy.exitCode(after: code, stopRequested: stopRequested)
    }

    /// Report an error that reached `main` and return its exit code.
    /// ArgumentParser's own main reports any thrown error with exit code 1
    /// and prints "Error: exit code N". Commands have already reported their
    /// errors when they throw BlewExitCode, so its code is returned quietly.
    static func report(_ error: Error) -> Int32 {
        if let code = error as? BlewExitCode { return code.code }
        let code = processExitCode(for: error)
        let message = fullMessage(for: error)
        if code == BlewExitCode.success.code {
            // `--help` and `--version` print their text and exit 0.
            guard !message.isEmpty else { return code }
            for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
                StandardOutput.write(TextLine(String(line)), styled: false)
            }
        } else {
            // The message quotes the command line, which is untrusted.
            StandardErrorLog.write(lines: message)
        }
        return code
    }

    /// The exit code for an error that reaches `main`: 0 for a request for
    /// help or the version, 6 (invalid arguments) for any usage or
    /// validation error ArgumentParser reports, which it would exit with 64,
    /// and otherwise the code `BlewExitCode(for:)` gives the error.
    static func processExitCode(for error: Error) -> Int32 {
        switch exitCode(for: error) {
        case .success: return BlewExitCode.success.code
        case .validationFailure: return BlewExitCode.invalidArguments.code
        default: return BlewExitCode(for: error).code
        }
    }

    mutating func validate() throws {
        GlobalOptions.current = globals
    }

    mutating func run() async throws {
        try REPL(globals: globals).run()
    }
}

/// The main thread's one way out, in every mode: claim the exit with
/// `code`, stop advertising and disconnect, and exit. When a signal has
/// already begun the exit, this waits for the signal's exit instead, so the
/// process ends with the signal's code (`ProcessSignals.beginOrdinaryExit`).
func exitOrdinarily(_ code: Int32) -> Never {
    ProcessSignals.shared.beginOrdinaryExit(with: code)
    exitCleanup()
    Foundation.exit(code)
}

/// Best-effort disconnect and stop advertising on process exit. Run once,
/// by whichever of the main thread and the signal queue owns the exit.
/// A CoreBluetooth manager nothing has created (no `CommandRouter` for
/// `--help` or a usage error; no peripheral for a central command) has
/// nothing to clean up, and is not created for it.
func exitCleanup() {
    if let peripheral = BLEPeripheral.sharedIfCreated, peripheral.isAdvertising() {
        peripheral.stopAdvertising()
    }

    guard let central = BLECentral.sharedIfCreated else { return }
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let status = await central.status()
        if status.isConnected {
            try? await central.disconnect()
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
