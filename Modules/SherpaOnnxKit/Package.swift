// swift-tools-version: 5.10
import PackageDescription

// sherpa-onnx (k2-fsa, Apache-2.0) + onnxruntime (Microsoft, MIT): the
// on-device runtime behind the SenseVoice speech engine in BentoVoiceKit.
// Nothing here is committed: both are official prebuilt binaries.
//
// - SherpaOnnx.xcframework is built by scripts/fetch-sherpa-onnx.sh from the
//   official sherpa-onnx v1.13.4 Apple xcframework zips (checksum-verified,
//   binaries untouched, iOS device + simulator + macOS merged, headers moved
//   one level down). It can't be a url binaryTarget: the official zips put
//   module.modulemap at the top of Headers/, exactly like GhosttyKit's, and
//   Xcode copies both into one include/ dir — "Multiple commands produce
//   …/include/module.modulemap". Run the script before building (CI does).
//   v1.13.4 is the newest release that publishes the Apple xcframework zips.
// - onnxruntime is Microsoft's own CocoaPods/SwiftPM archive (one static
//   framework xcframework: iOS, iOS simulator, macOS) at the version
//   sherpa-onnx v1.13.4 was built against. Framework-style headers, so no
//   clash; SwiftPM downloads it, checksum-pinned.
//
// Shape follows GhosttyKit on purpose: every product points straight at a
// binary target. SwiftPM does not re-export a binary target's C module
// through a wrapper target.
let package = Package(
    name: "SherpaOnnxKit",
    platforms: [
        .iOS(.v17),
        .macOS("27.0"),
    ],
    products: [
        .library(name: "SherpaOnnx", targets: ["SherpaOnnx"]),
        .library(name: "onnxruntime", targets: ["onnxruntime"]),
    ],
    targets: [
        // C module: `SherpaOnnxC`.
        .binaryTarget(
            name: "SherpaOnnx",
            path: "SherpaOnnx.xcframework"
        ),
        .binaryTarget(
            name: "onnxruntime",
            url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.27.0.zip",
            checksum: "8c74edd600eafc3055de9e8f7a9602afee44ed516913cb5e132bca02cc34622c"
        ),
    ]
)
