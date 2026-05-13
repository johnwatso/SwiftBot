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
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.9.6")
    ],
    targets: [
        .target(
            name: "UpdateEngine",
            dependencies: [
                .product(name: "SwiftSoup", package: "SwiftSoup")
            ],
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
