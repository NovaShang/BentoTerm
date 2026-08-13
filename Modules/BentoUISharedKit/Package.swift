// swift-tools-version: 5.10
import PackageDescription

// BentoUISharedKit: SwiftUI/AppKit views shared by both apps that belong to
// no single domain Kit — the window sidebar, architecture diagram, the
// pane drop-zone overlay, and the macOS new-pane directory accessory. The
// session ENGINE lives in BentoSessionKit; this package is its UI companion
// and depends on it (never the other way around).
let package = Package(
    name: "BentoUISharedKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BentoUISharedKit", targets: ["BentoUISharedKit"]),
    ],
    dependencies: [
        .package(path: "../BentoTmuxKit"),
        .package(path: "../BentoFoundationKit"),
        .package(path: "../BentoAgentKit"),
        .package(path: "../BentoSessionKit"),
        .package(path: "../BentoFilePreviewKit"),
    ],
    targets: [
        .target(
            name: "BentoUISharedKit",
            dependencies: [
                "BentoTmuxKit",
                "BentoFoundationKit",
                "BentoAgentKit",
                "BentoSessionKit",
                "BentoFilePreviewKit",
            ]
        ),
        .testTarget(
            name: "BentoUISharedKitTests",
            dependencies: ["BentoUISharedKit"]
        ),
    ]
)
