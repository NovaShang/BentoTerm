// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BentoFilePreviewKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BentoFilePreviewKit",
            targets: ["BentoFilePreviewKit"]
        ),
    ],
    dependencies: [
        .package(path: "../BentoFoundationKit"),
    ],
    targets: [
        .target(
            name: "BentoFilePreviewKit",
            dependencies: ["BentoFoundationKit"],
            resources: [
                .copy("Resources/PathPreview"),
            ]
        ),
        .testTarget(
            name: "BentoFilePreviewKitTests",
            dependencies: ["BentoFilePreviewKit"]
        ),
    ]
)
