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
        ),
        .executable(
            name: "UpdateEngineTester",
            targets: ["UpdateEngineTester"]
        ),
        .executable(
            name: "UpdateEngineUITester",
            targets: ["UpdateEngineUITester"]
        )
    ],
    targets: [
        .target(
            name: "UpdateEngine",
            path: "Sources/UpdateEngineCore"
        ),
        .executableTarget(
            name: "UpdateEngineTester",
            dependencies: ["UpdateEngine"],
            path: "Sources/UpdateEngineTester"
        ),
        .executableTarget(
            name: "UpdateEngineUITester",
            dependencies: ["UpdateEngine"],
            path: "Sources/UpdateEngineUITester"
        ),
        .testTarget(
            name: "UpdateEngineTests",
            dependencies: ["UpdateEngine"],
            path: "Tests/UpdateEngineTests"
        ),
    ]
)
