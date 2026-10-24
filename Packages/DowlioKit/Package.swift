// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DowlioKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DowlioCore", targets: ["DowlioCore"]),
        .library(name: "DowlioEngine", targets: ["DowlioEngine"]),
        .library(name: "DowlioStore", targets: ["DowlioStore"]),
        .library(name: "DowlioLibrary", targets: ["DowlioLibrary"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(name: "DowlioCore"),
        .target(name: "DowlioEngine", dependencies: ["DowlioCore"]),
        .target(name: "DowlioStore", dependencies: ["DowlioCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "DowlioLibrary", dependencies: ["DowlioCore", "DowlioEngine", "DowlioStore"]),
        .executableTarget(name: "dowlio-cli", dependencies: ["DowlioEngine"]),
        // Test infrastructure shared by test targets. Never shipped.
        .target(name: "DowlioTestSupport", dependencies: ["DowlioCore", "DowlioEngine"]),
        .testTarget(name: "DowlioCoreTests", dependencies: ["DowlioCore"]),
        .testTarget(
            name: "DowlioEngineTests",
            dependencies: ["DowlioEngine", "DowlioTestSupport", "dowlio-cli"]
        ),
        .testTarget(name: "DowlioLibraryTests", dependencies: ["DowlioLibrary", "DowlioStore", "DowlioTestSupport"]),
    ]
)
