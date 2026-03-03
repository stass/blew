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
        abstract: "List discovered services"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = targeting.toArgs()
        args.append("svcs")
        let result = router.runGATT(args)
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}

struct GATTTreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Show full GATT tree"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Flag(name: [.short, .long], help: "Include descriptors.")
    var descriptors: Bool = false

    @Flag(name: [.customShort("r"), .customLong("read")], help: "Read and display values for readable characteristics.")
    var readValues: Bool = false

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = targeting.toArgs()
        args.append("tree")
        if descriptors { args.append("-d") }
        if readValues { args.append("-r") }
        let result = router.runGATT(args)
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}

struct GATTCharsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chars",
        abstract: "List characteristics for a service"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Flag(name: [.customShort("r"), .customLong("read")], help: "Read and display values for readable characteristics.")
    var readValues: Bool = false

    @Argument(help: "Service UUID.")
    var service: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = targeting.toArgs()
        args += ["chars", service]
        if readValues { args.append("-r") }
        let result = router.runGATT(args)
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}

struct GATTDescCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "desc",
        abstract: "List descriptors for a characteristic"
    )

    @OptionGroup var targeting: DeviceTargetingOptions

    @Argument(help: "Characteristic UUID.")
    var char: String

    mutating func run() throws {
        let router = CommandRouter(globals: GlobalOptions.current)
        var args = targeting.toArgs()
        args += ["desc", char]
        let result = router.runGATT(args)
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
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
        let result = router.runGATT(["info", char])
        router.renderer.renderResult(result)
        if result.exitCode != 0 { throw BlewExitCode(result.exitCode) }
    }
}
