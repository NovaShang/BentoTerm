// swift-tools-version: 5.10
import PackageDescription

// The engine talks to surfaces only through the ghostty-free TerminalSurface
// protocol. Everything libghostty-flavored lives ABOVE this package:
// BentoGhosttyKit (runtime + the two platform surfaces) depends on core, and
// the app targets import it directly.
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
