// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SSHTunnelManager",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        // RoyalVNC must be pinned by revision (not version): it transitively
        // depends on a branch of CryptoSwift, and SwiftPM forbids a version-pinned
        // package from depending on a branch-pinned one. 92d4427 == tag 1.1.0.
        .package(url: "https://github.com/royalapplications/royalvnc.git", revision: "92d4427c73817d8f849bb289ff190aa4b40c44ea")
    ],
    targets: [
        .executableTarget(
            name: "SSHTunnelManager",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "RoyalVNCKit", package: "royalvnc")
            ],
            path: "Sources/SSHTunnelManager"
        )
    ]
)
