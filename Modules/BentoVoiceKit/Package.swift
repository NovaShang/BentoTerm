// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BentoVoiceKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BentoVoiceKit",
            targets: ["BentoVoiceKit"]
        ),
    ],
    dependencies: [
        .package(path: "../BentoFoundationKit"),
    ],
    targets: [
        .target(
            name: "BentoVoiceKit",
            dependencies: ["BentoFoundationKit"]
        ),
        .testTarget(
            name: "BentoVoiceKitTests",
            dependencies: ["BentoVoiceKit"]
        ),
    ]
)
