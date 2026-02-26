import PackagePlugin
import Foundation

@main
struct GenerateBLENames: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let script = context.package.directory.appending("Scripts/generate-ble-names.rb")
        let dataDir = context.package.directory.appending("Vendor/bluetooth-numbers-database/v1")
        let outputFile = context.pluginWorkDirectory.appending("BLENames.generated.swift")

        return [
            .prebuildCommand(
                displayName: "Generate BLE SIG names",
                executable: Path("/usr/bin/env"),
                arguments: ["ruby", script.string, dataDir.string, outputFile.string],
                outputFilesDirectory: context.pluginWorkDirectory
            )
        ]
    }
}
