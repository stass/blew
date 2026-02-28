// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "blew",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "blew",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "LineNoise",
                "BLEManager",
            ],
            exclude: ["Info.plist"],
            plugins: [
                .plugin(name: "GenerateBLENames"),
            ]
        ),
        .plugin(
            name: "GenerateBLENames",
            capability: .buildTool()
        ),
        .target(
            name: "LineNoise"
        ),
        .target(
            name: "BLEManager",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
            ]
        ),
        .testTarget(
            name: "blewTests",
            dependencies: ["blew"]
        ),
    ]
)
