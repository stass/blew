import PackagePlugin
import Foundation

@main
struct GenerateBLENames: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let packageDir = context.package.directoryURL
        let wrapper = packageDir.appending(path: "Scripts/generate-all-ble.sh")
        let namesDataDir = packageDir.appending(path: "Vendor/bluetooth-numbers-database/v1")
        let sigDir = packageDir.appending(path: "Vendor/bluetooth-SIG")
        let workDir = context.pluginWorkDirectoryURL

        return [
            .prebuildCommand(
                displayName: "Generate BLE SIG names and characteristic definitions",
                executable: wrapper,
                arguments: [namesDataDir.path(percentEncoded: false), sigDir.path(percentEncoded: false), workDir.path(percentEncoded: false)],
                outputFilesDirectory: workDir
            ),
        ]
    }
}
