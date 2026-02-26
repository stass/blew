import PackagePlugin
import Foundation

@main
struct GenerateBLENames: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let wrapper = context.package.directory.appending("Scripts/generate-all-ble.sh")
        let namesDataDir = context.package.directory.appending("Vendor/bluetooth-numbers-database/v1")
        let sigDir = context.package.directory.appending("Vendor/bluetooth-SIG")

        return [
            .prebuildCommand(
                displayName: "Generate BLE SIG names and characteristic definitions",
                executable: wrapper,
                arguments: [namesDataDir.string, sigDir.string, context.pluginWorkDirectory.string],
                outputFilesDirectory: context.pluginWorkDirectory
            ),
        ]
    }
}
