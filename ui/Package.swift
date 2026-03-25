// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VoxBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "VoxBar", targets: ["VoxBar"]),
    ],
    targets: [
        .executableTarget(
            name: "VoxBar",
            path: "Sources/VoxBar"
        ),
    ]
)
