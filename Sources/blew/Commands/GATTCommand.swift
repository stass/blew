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

    @Flag(name: .customShort("V"), help: "Read and display values for readable characteristics.")
    var values: Bool = false

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args: [String] = ["tree"]
        if descriptors { args.append("-d") }
        if values { args.append("-V") }
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

    @Option(name: [.customShort("S"), .long], help: "Service UUID.")
    var service: String

    @Flag(name: .customShort("V"), help: "Read and display values for readable characteristics.")
    var values: Bool = false

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args: [String] = ["chars", "-S", service]
        if values { args.append("-V") }
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

    @Option(name: [.customShort("c"), .long], help: "Characteristic UUID.")
    var char: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        let code = router.runGATT(["desc", "-c", char])
        if code != 0 { throw BlewExitCode(code) }
    }
}
