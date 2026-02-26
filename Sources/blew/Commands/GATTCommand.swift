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
        abstract: "List discovered services"
    )

    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        let router = CommandRouter(globals: globals)
        let code = router.runGATT(["svcs"])
        if code != 0 { throw BlewExitCode(code) }
    }
}

struct GATTTreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Show full GATT tree"
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: [.short, .long], help: "Include descriptors.")
    var descriptors: Bool = false

    mutating func run() throws {
        let router = CommandRouter(globals: globals)
        var args: [String] = ["tree"]
        if descriptors { args.append("-d") }
        let code = router.runGATT(args)
        if code != 0 { throw BlewExitCode(code) }
    }
}

struct GATTCharsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chars",
        abstract: "List characteristics for a service"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: [.customShort("S"), .long], help: "Service UUID.")
    var service: String

    mutating func run() throws {
        let router = CommandRouter(globals: globals)
        let code = router.runGATT(["chars", "-S", service])
        if code != 0 { throw BlewExitCode(code) }
    }
}

struct GATTDescCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "desc",
        abstract: "List descriptors for a characteristic"
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: [.customShort("c"), .long], help: "Characteristic UUID.")
    var char: String

    mutating func run() throws {
        let router = CommandRouter(globals: globals)
        let code = router.runGATT(["desc", "-c", char])
        if code != 0 { throw BlewExitCode(code) }
    }
}
