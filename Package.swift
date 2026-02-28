// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiscordBotApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DiscordBotApp", targets: ["DiscordBotApp"])
    ],
    targets: [
        .executableTarget(
            name: "DiscordBotApp",
            path: "DiscordBotApp",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
