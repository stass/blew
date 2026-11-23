// swift-tools-version: 6.0

import PackageDescription

// The MCP swift-sdk dependency declares swift-tools-version:6.1 and uses
// concurrency APIs introduced in Swift 6.1. When built with an older toolchain
// (Swift 6.0.x / Xcode 16.2 and earlier) the MCP server is omitted so the rest
// of blew still builds. The `MCP_ENABLED` define gates the MCP source files.
#if compiler(>=6.1)
let mcpEnabled = true
#else
let mcpEnabled = false
#endif

let mcpPackageDependency: [Package.Dependency] = mcpEnabled
    ? [.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0")]
    : []

let mcpTargetDependency: [Target.Dependency] = mcpEnabled
    ? [.product(name: "MCP", package: "swift-sdk")]
    : []

let mcpSwiftSettings: [SwiftSetting] = mcpEnabled ? [.define("MCP_ENABLED")] : []

let package = Package(
    name: "blew",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ] + mcpPackageDependency,
    targets: [
        .executableTarget(
            name: "blew",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "LineNoise",
                "BLEManager",
            ] + mcpTargetDependency,
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)] + mcpSwiftSettings,
            plugins: [
                .plugin(name: "GenerateBLENames"),
            ]
        ),
        .plugin(
            name: "GenerateBLENames",
            capability: .buildTool()
        ),
        .target(
            name: "LineNoise",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BLEManager",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
            ]
        ),
        .testTarget(
            name: "blewTests",
            dependencies: [
                "blew",
                "LineNoise",
            ] + mcpTargetDependency,
            swiftSettings: [.swiftLanguageMode(.v5)] + mcpSwiftSettings
        ),
    ]
)
