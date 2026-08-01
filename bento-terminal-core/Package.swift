// swift-tools-version: 5.10
import PackageDescription

// GhosttyKit is the libghostty C library packaged as an xcframework.
// For now we consume the prebuilt MIT-Ghostty build published by TermBridgeKit
// (the binary is a build of MIT-licensed Ghostty with the external-backend
// patch needed to feed SSH bytes on iOS). Before shipping we will replace this
// with our own xcframework built from the `ios-external-backend` fork and
// vendor it under Frameworks/ (see project_ghostty_feasibility memory).
let ghosttyKit: Target = .binaryTarget(
    name: "GhosttyKit",
    url: "https://github.com/arach/TermBridgeKit/releases/download/0.1.5/GhosttyKit.xcframework.zip",
    checksum: "d9246242185d9ce5d4ee45fb0ff3fbc520aa995641dea9b198e43e1e4538b759"
)

// System frameworks the static libghostty needs to link.
let coreLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("c++"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("CoreText"),
    .linkedFramework("Metal"),
    .linkedFramework("AppKit", .when(platforms: [.macOS])),
    .linkedFramework("Carbon", .when(platforms: [.macOS])),
    .linkedFramework("UIKit", .when(platforms: [.iOS])),
    .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
]

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
        .package(path: "../Modules/BentoVoiceKit"),
        .package(path: "../Modules/BentoFoundationKit"),
        .package(path: "../Modules/BentoFilePreviewKit"),
    ],
    targets: [
        ghosttyKit,
        .target(
            name: "BentoTerminalCore",
            dependencies: [
                "GhosttyKit",
                .product(name: "BentoTmuxKit", package: "BentoTmuxKit"),
                "BentoVoiceKit",
                "BentoFoundationKit",
                "BentoFilePreviewKit",
            ],
            linkerSettings: coreLinkerSettings
        ),
        .testTarget(
            name: "BentoTerminalCoreTests",
            dependencies: ["BentoTerminalCore"]
        ),
    ]
)
