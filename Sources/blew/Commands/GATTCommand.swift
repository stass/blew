import ArgumentParser
import Foundation
import BLEManager

struct GATTCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gatt",
        abstract: "Inspect GATT services and characteristics",
        subcommands: [
            GATTSvcsCommand.self,
            GATTTreeCommand.self,
            GATTCharsCommand.self,
            GATTDescCommand.self,
            GATTInfoCommand.self,
        ]
    )
}

struct GATTSvcsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "svcs",
        abstract: "List discovered services",
        discussion: "Device targeting and output options are global options; pass them before the subcommand name (see blew --help)."
    )

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        let code = router.runGATT(["svcs"])
        if code != 0 { throw BlewExitCode(code) }
    }
}

struct GATTTreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Show full GATT tree",
        discussion: "Device targeting and output options are global options; pass them before the subcommand name (see blew --help)."
    )

    @Flag(name: [.short, .long], help: "Include descriptors.")
    var descriptors: Bool = false

    @Flag(name: [.customShort("r"), .customLong("read")], help: "Read and display values for readable characteristics.")
    var readValues: Bool = false

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args: [String] = ["tree"]
        if descriptors { args.append("-d") }
        if readValues { args.append("-r") }
        let code = router.runGATT(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}

struct GATTCharsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chars",
        abstract: "List characteristics for a service",
        discussion: "Device targeting and output options are global options; pass them before the subcommand name (see blew --help)."
    )

    @Flag(name: [.customShort("r"), .customLong("read")], help: "Read and display values for readable characteristics.")
    var readValues: Bool = false

    @Argument(help: "Service UUID.")
    var service: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args: [String] = ["chars", service]
        if readValues { args.append("-r") }
        let code = router.runGATT(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}

struct GATTDescCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "desc",
        abstract: "List descriptors for a characteristic",
        discussion: "Device targeting and output options are global options; pass them before the subcommand name (see blew --help)."
    )

    @Argument(help: "Characteristic UUID.")
    var char: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        let code = router.runGATT(["desc", char])
        if code != 0 { throw BlewExitCode(code) }
    }
}

struct GATTInfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show Bluetooth SIG description for a standard characteristic UUID",
        discussion: "Does not require a connected device. Shows the characteristic name, description, and field structure from the Bluetooth SIG specification."
    )

    @Argument(help: "Characteristic UUID (4-char or full form).")
    var char: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        let code = router.runGATT(["info", char])
        if code != 0 { throw BlewExitCode(code) }
    }
}
