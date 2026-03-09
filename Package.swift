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
        .package(path: "Sources/UpdateEngine"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0")
    ],
    targets: [
        .executableTarget(
            name: "SwiftBot",
            dependencies: [
                .product(name: "UpdateEngine", package: "UpdateEngine"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            path: "SwiftBotApp",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "SparklePublisher",
            path: "Tools/SparklePublisher"
        ),
        .testTarget(
            name: "SwiftBotTests",
            dependencies: [
                "SwiftBot",
                .product(name: "UpdateEngine", package: "UpdateEngine")
            ],
            path: "Tests/SwiftBotTests"
        )
    ]
)
