// swift-tools-version: 5.10
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
        .package(path: "../SherpaOnnxKit"),
    ],
    targets: [
        .target(
            name: "BentoVoiceKit",
            dependencies: [
                "BentoFoundationKit",
                // On-device speech runtime (SenseVoice). SherpaOnnx.xcframework
                // comes from scripts/fetch-sherpa-onnx.sh — run it first.
                .product(name: "SherpaOnnx", package: "SherpaOnnxKit"),
                .product(name: "onnxruntime", package: "SherpaOnnxKit"),
            ],
            // Silero VAD (MIT, github.com/snakers4/silero-vad), 644 KB, as
            // published in sherpa-onnx's asr-models release — it cuts a hold
            // into segments for the on-device engine's live text.
            resources: [.copy("Resources/silero_vad.onnx")],
            swiftSettings: [
                // Makes `@_implementationOnly import SherpaOnnxC` checked
                // (and silences its warning) without library evolution.
                .enableExperimentalFeature("CheckImplementationOnly"),
            ],
            linkerSettings: [
                // sherpa-onnx and onnxruntime are static C++ archives.
                .linkedLibrary("c++"),
                // onnxruntime's Apple build carries the CoreML execution
                // provider, which references CoreML even when only the CPU
                // provider is used.
                .linkedFramework("CoreML"),
                .linkedFramework("Foundation"),
            ]
        ),
        .testTarget(
            name: "BentoVoiceKitTests",
            dependencies: ["BentoVoiceKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
