// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DowlioKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DowlioCore", targets: ["DowlioCore"]),
        .library(name: "DowlioEngine", targets: ["DowlioEngine"]),
        .executable(name: "dowlio-cli", targets: ["dowlio-cli"]),
    ],
    targets: [
        .target(name: "DowlioCore"),
        .target(name: "DowlioEngine", dependencies: ["DowlioCore"]),
        .executableTarget(name: "dowlio-cli", dependencies: ["DowlioEngine"]),
        // Test infrastructure shared by test targets. Never shipped.
        .target(name: "DowlioTestSupport", dependencies: ["DowlioCore", "DowlioEngine"]),
        .testTarget(name: "DowlioCoreTests", dependencies: ["DowlioCore"]),
        .testTarget(
            name: "DowlioEngineTests",
            dependencies: ["DowlioEngine", "DowlioTestSupport", "dowlio-cli"]
        ),
    ]
)
