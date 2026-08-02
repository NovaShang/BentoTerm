// swift-tools-version: 5.10
import PackageDescription

// BentoGhosttyKit (the libghostty managed-host layer) lives in
// Modules/BentoGhosttyKit as its own package — the engine here talks to
// surfaces only through the ghostty-free TerminalSurface protocol, and the
// Mac/iOS app targets import GhosttyKit (the raw xcframework) directly.
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
        .package(path: "../Modules/BentoGhosttyKit"),
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
                .product(name: "BentoGhosttyKit", package: "BentoGhosttyKit"),
                .product(name: "BentoTmuxKit", package: "BentoTmuxKit"),
                .product(name: "BentoAgentKit", package: "BentoAgentKit"),
                "BentoVoiceKit",
                "BentoFoundationKit",
                "BentoFilePreviewKit",
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
