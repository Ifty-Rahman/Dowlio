// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DowlioKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DowlioCore", targets: ["DowlioCore"]),
    ],
    targets: [
        .target(name: "DowlioCore"),
        .testTarget(name: "DowlioCoreTests", dependencies: ["DowlioCore"]),
    ]
)
