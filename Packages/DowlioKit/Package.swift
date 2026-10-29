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
        .library(name: "DowlioConnect", targets: ["DowlioConnect"]),
        .library(name: "DowlioMedia", targets: ["DowlioMedia"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(name: "DowlioCore"),
        .target(name: "DowlioEngine", dependencies: ["DowlioCore"]),
        .target(name: "DowlioStore", dependencies: ["DowlioCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "DowlioLibrary", dependencies: ["DowlioCore", "DowlioEngine", "DowlioMedia", "DowlioStore"]),
        .target(name: "DowlioMedia", dependencies: ["DowlioCore"]),
        .target(name: "DowlioConnect", dependencies: ["DowlioCore", "DowlioEngine", "DowlioStore", "DowlioLibrary", "DowlioMedia"]),
        .executableTarget(name: "dowlio-cli", dependencies: ["DowlioEngine", "DowlioMedia"]),
        // Test infrastructure shared by test targets. Never shipped.
        .target(name: "DowlioTestSupport", dependencies: ["DowlioCore", "DowlioEngine"], resources: [.copy("Resources/Media")]),
        .testTarget(name: "DowlioCoreTests", dependencies: ["DowlioCore"]),
        .testTarget(
            name: "DowlioEngineTests",
            dependencies: ["DowlioEngine", "DowlioTestSupport", "dowlio-cli"]
        ),
        .testTarget(name: "DowlioConnectTests", dependencies: ["DowlioConnect", "DowlioCore", "DowlioEngine", "DowlioLibrary", "DowlioMedia", "DowlioStore", "DowlioTestSupport"]),
        .testTarget(
            name: "DowlioMediaTests",
            dependencies: ["DowlioMedia", "DowlioCore", "DowlioEngine", "DowlioTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "DowlioLibraryTests", dependencies: ["DowlioLibrary", "DowlioMedia", "DowlioStore", "DowlioTestSupport"]),
    ]
)
