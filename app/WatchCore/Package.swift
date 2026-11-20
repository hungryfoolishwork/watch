// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "WatchCore",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "WatchCore", targets: ["WatchCore"]),
        .library(name: "WatchProtocol", targets: ["WatchProtocol"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WatchProtocol",
        ),
        .target(
            name: "WatchCore",
            dependencies: [
                "WatchProtocol",
            ]
        ),
        .testTarget(
            name: "WatchCoreTests",
            dependencies: [
                "WatchCore",
            ]
        ),
    ]
)
