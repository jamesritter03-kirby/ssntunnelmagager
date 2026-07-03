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
                .product(name: "RoyalVNCKit", package: "royalvnc"),
                "ScintillaEngine"
            ],
            path: "Sources/SSHTunnelManager"
        ),

        // Scintilla 5.6.3 + Lexilla 5.5.0, vendored as a single mixed
        // C++/Objective-C++ target. Only the pure-Objective-C SciEditorView.h
        // (in include/) is exposed to Swift; every C++ / Scintilla header stays
        // internal via the header search paths below so the generated Clang
        // module the Swift side imports remains clean.
        .target(
            name: "ScintillaEngine",
            path: "Sources/ScintillaEngine",
            exclude: [
                "LICENSE-Scintilla.txt",
                "LICENSE-Lexilla.txt"
            ],
            sources: [
                "bridge",
                "scintilla/src",
                "scintilla/cocoa",
                "lexilla/src",
                "lexilla/lexlib",
                "lexilla/lexers"
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("scintilla/include"),
                .headerSearchPath("scintilla/src"),
                .headerSearchPath("scintilla/cocoa"),
                .headerSearchPath("lexilla/include"),
                .headerSearchPath("lexilla/lexlib"),
                // ARC is required by Scintilla's Cocoa layer; clang ignores the
                // flag for the pure-C++ (.cxx) translation units. -w silences the
                // large volume of upstream warnings so our own output stays clean.
                .unsafeFlags(["-fobjc-arc", "-w"])
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
