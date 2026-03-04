// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "blew",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "blew",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk"),
                "LineNoise",
                "BLEManager",
            ],
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
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
            dependencies: ["blew"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
