// swift-tools-version: 5.10
import PackageDescription

// GhosttyKit (libghostty xcframework + its linker settings) now lives in
// Modules/GhosttyKit as its own package — shared by this engine and the
// BentoTermMac target's UI layer, which imports GhosttyKit directly.
let package = Package(
    name: "BentoTerminalCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BentoTerminalCore", targets: ["BentoTerminalCore"]),
    ],
    dependencies: [
        .package(path: "../Modules/GhosttyKit"),
        .package(path: "../Modules/BentoTmuxKit"),
        .package(path: "../Modules/BentoAgentKit"),
        .package(path: "../Modules/BentoVoiceKit"),
        .package(path: "../Modules/BentoFoundationKit"),
        .package(path: "../Modules/BentoFilePreviewKit"),
    ],
    targets: [
        .target(
            name: "BentoTerminalCore",
            dependencies: [
                .product(name: "GhosttyKit", package: "GhosttyKit"),
                .product(name: "BentoTmuxKit", package: "BentoTmuxKit"),
                .product(name: "BentoAgentKit", package: "BentoAgentKit"),
                "BentoVoiceKit",
                "BentoFoundationKit",
                "BentoFilePreviewKit",
            ],
            // The static libghostty needs these at link time. They live on the
            // consumers (here and the Mac target) because the GhosttyKit
            // package exposes just the binary target.
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Metal"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(
            name: "BentoTerminalCoreTests",
            dependencies: [
                "BentoTerminalCore",
                // PathDetector's core-side consumers (PathHitTester / tap-candidate
                // tests) live in core, so the mixed tests import the preview kit.
                "BentoFilePreviewKit",
            ]
        ),
    ]
)
