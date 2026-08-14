// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BentoAgentKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BentoAgentKit",
            targets: ["BentoAgentKit"]
        ),
    ],
    dependencies: [
        .package(path: "../BentoTmuxKit"),
    ],
    targets: [
        .target(
            name: "BentoAgentKit",
            dependencies: [
                .product(name: "BentoTmuxKit", package: "BentoTmuxKit"),
            ]
        ),
        .testTarget(
            name: "BentoAgentKitTests",
            dependencies: ["BentoAgentKit"],
            // Real `capture-pane -p -J` output from live agent sessions, kept
            // verbatim: the rules are claims about what these agents put on
            // screen, and a hand-typed approximation can't falsify them.
            resources: [.copy("Fixtures")]
        ),
    ]
)
