// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "WatchKit",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "WatchKit", targets: ["WatchKit"]),
    ],
    dependencies: [
        .package(path: "../WatchCore"),
    ],
    targets: [
        .target(
            name: "WatchKit",
            dependencies: [
                .product(name: "WatchProtocol", package: "WatchCore"),
            ],
            resources: [
                .process("Assets.xcassets"),
            ]
        ),
        .testTarget(
            name: "WatchKitTests",
            dependencies: ["WatchKit"]
        ),
    ]
)
