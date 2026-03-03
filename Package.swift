// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftBot",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "SwiftBot", targets: ["SwiftBot"]),
        .executable(name: "SparklePublisher", targets: ["SparklePublisher"])
    ],
    dependencies: [
        .package(path: "Sources/UpdateEngine")
    ],
    targets: [
        .executableTarget(
            name: "SwiftBot",
            dependencies: [
                .product(name: "UpdateEngine", package: "UpdateEngine")
            ],
            path: "SwiftBotApp",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "SparklePublisher",
            path: "Tools/SparklePublisher"
        )
    ]
)
