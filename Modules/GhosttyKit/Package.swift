// swift-tools-version: 5.10
import PackageDescription

// libghostty C library packaged as an xcframework. Shared by BentoTerminalCore
// (engine) and the BentoTermMac target's UI layer (which imports GhosttyKit
// directly). Previously a private binary target inside bento-terminal-core.
//
// The product exposes the binary target directly: SwiftPM does not re-export
// a binary target's C module through a wrapper target, so consumers must
// depend on it directly. Linker settings for the static libghostty live on
// the consuming targets (see bento-terminal-core/Package.swift).
let package = Package(
    name: "GhosttyKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            url: "https://github.com/arach/TermBridgeKit/releases/download/0.1.5/GhosttyKit.xcframework.zip",
            checksum: "d9246242185d9ce5d4ee45fb0ff3fbc520aa995641dea9b198e43e1e4538b759"
        ),
    ]
)
