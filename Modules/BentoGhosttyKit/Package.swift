// swift-tools-version: 5.10
import PackageDescription

// BentoGhosttyKit: the managed-host layer for libghostty. The GhosttyKit
// package carries only the prebuilt xcframework; this package owns everything
// Bento does with it — runtime lifecycle, C-callback routing, selection /
// mouse / clipboard bridging, and the ghostty-typed surface callback protocol.
// Core's shared engine never names a ghostty type; it talks to the
// engine-agnostic TerminalSurface protocol.
let package = Package(
    name: "BentoGhosttyKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BentoGhosttyKit", targets: ["BentoGhosttyKit"]),
    ],
    dependencies: [
        .package(path: "../GhosttyKit"),
        .package(path: "../BentoFoundationKit"),
    ],
    targets: [
        .target(
            name: "BentoGhosttyKit",
            dependencies: [
                .product(name: "GhosttyKit", package: "GhosttyKit"),
                "BentoFoundationKit",
            ],
            // The static libghostty needs these at link time. They live on the
            // consumers of the binary (this package — previously core) because
            // the GhosttyKit package exposes just the binary target.
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
    ]
)
