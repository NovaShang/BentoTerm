// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BentoAgentKit",
    platforms: [
        .iOS(.v17),
        .macOS("27.0"),
    ],
    products: [
        .library(
            name: "BentoAgentKit",
            targets: ["BentoAgentKit"]
        ),
    ],
    dependencies: [
        .package(path: "../BentoTmuxKit"),
        .package(path: "../BentoFoundationKit"),
    ],
    targets: [
        .target(
            name: "BentoAgentKit",
            dependencies: [
                .product(name: "BentoTmuxKit", package: "BentoTmuxKit"),
                .product(name: "BentoFoundationKit", package: "BentoFoundationKit"),
            ]
        ),
        .testTarget(
            name: "BentoAgentKitTests",
            dependencies: ["BentoAgentKit"]
        ),
    ]
)
