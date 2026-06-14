// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SSHTunnelManager",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "SSHTunnelManager",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/SSHTunnelManager"
        )
    ]
)
