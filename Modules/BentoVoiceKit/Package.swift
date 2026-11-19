// swift-tools-version: 6.2
// 6.2, not 5.10: package traits (the `traits: []` on FluidAudio below) need
// tools 6.2. The language mode stays Swift 5 — the bump is for the manifest
// only.
import PackageDescription

let package = Package(
    name: "BentoVoiceKit",
    platforms: [
        .iOS(.v17),
        .macOS("27.0"),
    ],
    products: [
        .library(
            name: "BentoVoiceKit",
            targets: ["BentoVoiceKit"]
        ),
    ],
    dependencies: [
        .package(path: "../BentoFoundationKit"),
        // FluidAudio (FluidInference, Apache-2.0): runs SenseVoiceSmall and
        // Silero VAD as Core ML on the system's own engine, so the on-device
        // speech engine ships no inference runtime of its own. Exact version:
        // its API moves between minors.
        //
        // `traits: []` turns off its default traits — TTS, Diarizer and the
        // NeMo text-normalization engine (a prebuilt Rust staticlib, ~8 MB a
        // slice). We only use ASR + VAD, which are always built.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: []),
    ],
    targets: [
        .target(
            name: "BentoVoiceKit",
            dependencies: [
                "BentoFoundationKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "BentoVoiceKitTests",
            dependencies: ["BentoVoiceKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
