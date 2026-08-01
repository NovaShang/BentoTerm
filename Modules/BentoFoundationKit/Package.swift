// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BentoFoundationKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BentoFoundationKit",
            targets: ["BentoFoundationKit"]
        ),
    ],
    targets: [
        .target(
            name: "BentoFoundationKit"
        ),
        .testTarget(
            name: "BentoFoundationKitTests",
            dependencies: ["BentoFoundationKit"]
        ),
    ]
)
