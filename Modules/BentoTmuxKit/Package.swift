// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BentoTmuxKit",
    platforms: [
        .iOS(.v17),
        .macOS("27.0"),
    ],
    products: [
        .library(
            name: "BentoTmuxKit",
            targets: ["BentoTmuxKit"]
        ),
    ],
    targets: [
        .target(
            name: "BentoTmuxKit"
        ),
        .testTarget(
            name: "BentoTmuxKitTests",
            dependencies: ["BentoTmuxKit"]
        ),
    ]
)
