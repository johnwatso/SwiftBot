// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftBot",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "SwiftBot", targets: ["SwiftBot"])
    ],
    targets: [
        .executableTarget(
            name: "SwiftBot",
            path: "SwiftBotApp",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
