// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "UpdateEngine",
    platforms: [
        .macOS(.v14)  // macOS Sonoma or newer (required for onChange(of:initial:_:))
    ],
    dependencies: [
        // Add any dependencies here if needed
    ],
    targets: [
        .executableTarget(
            name: "UpdateEngine",
            dependencies: [],
            exclude: [
                "SwiftBotApp.swift",
                "UpdatePollingManager.swift",
                "GuildUpdateService.swift",
                "ConfigurationLoader.swift",
                "SwiftBotIntegrationExample.swift",
                "PerGuildIntegrationExample.swift"
            ]
        ),
    ]
)
