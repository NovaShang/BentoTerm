// swift-tools-version: 5.10
import PackageDescription

// BentoSessionKit: the session engine. TerminalViewModel owns one session's
// full lifecycle (SSH → session choice → tmux -CC / plain shell → per-pane
// state → reconnect) and every @Published state the UI reads. It sits ABOVE
// the domain Kits and BELOW the apps — the apps compose it with the surface
// layer (BentoGhosttyKit) via the TerminalSurface protocol (in
// BentoFoundationKit). No app code lives here; no surface code lives here.
let package = Package(
    name: "BentoSessionKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BentoSessionKit", targets: ["BentoSessionKit"]),
    ],
    dependencies: [
        .package(path: "../BentoTmuxKit"),
        .package(path: "../BentoFoundationKit"),
        .package(path: "../BentoAgentKit"),
        .package(path: "../BentoVoiceKit"),
        .package(path: "../BentoFilePreviewKit"),
    ],
    targets: [
        .target(
            name: "BentoSessionKit",
            dependencies: [
                "BentoTmuxKit",
                "BentoFoundationKit",
                "BentoAgentKit",
                "BentoVoiceKit",
                "BentoFilePreviewKit",
            ]
        ),
        .testTarget(
            name: "BentoSessionKitTests",
            dependencies: ["BentoSessionKit"]
        ),
    ]
)
