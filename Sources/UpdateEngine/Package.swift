// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "UpdateEngine",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "UpdateEngine",
            targets: ["UpdateEngine"]
        )
    ],
    targets: [
        .target(
            name: "UpdateEngine",
            path: "Sources/UpdateEngineCore"
        ),
        .testTarget(
            name: "UpdateEngineTests",
            dependencies: ["UpdateEngine"],
            path: "Tests/UpdateEngineTests"
        ),
    ]
)
