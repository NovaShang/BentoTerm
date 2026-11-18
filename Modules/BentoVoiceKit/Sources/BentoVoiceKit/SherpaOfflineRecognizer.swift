import Foundation
import BentoFoundationKit
// Implementation-only: no sherpa-onnx type crosses this file's API, so the
// modules that import BentoVoiceKit (the session kit, the apps, the tests) never
// need to find the `SherpaOnnxC` module map themselves — the binary target's C
// module does not propagate across packages (see Modules/SherpaOnnxKit).
@_implementationOnly import SherpaOnnxC

/// One loaded sherpa-onnx offline (non-streaming) model behind its C API. Not
/// thread-safe on its own — `OnDeviceASREngine` owns the only instance and
/// drives it from a single serial queue.
final class SherpaOfflineRecognizer {
    private let recognizer: OpaquePointer

    /// Load the model. Throws when sherpa-onnx refuses the files (it returns
    /// NULL for a missing/corrupt model rather than crashing).
    init(model: OnDeviceASRModel, directory: URL,
         numThreads: Int32 = SherpaOfflineRecognizer.defaultThreads) throws {
        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

        // The C config holds borrowed `const char *`s; strdup keeps every one
        // alive until Create returns (it copies what it needs).
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }

        // Zero-initialised: every model family we don't use stays NULL/0,
        // which is how sherpa-onnx tells which one is configured (and a 0 in a
        // numeric field means "its default").
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(OnDeviceASRModel.sampleRate)
        config.feat_config.feature_dim = 80
        config.model_config.num_threads = numThreads
        config.model_config.debug = 0
        config.model_config.provider = c("cpu")
        config.decoding_method = c("greedy_search")

        switch model.family {
        case .senseVoice:
            config.model_config.sense_voice.model = c(path("model.int8.onnx"))
            // "auto" = zh/en/ja/ko/yue detected per utterance.
            config.model_config.sense_voice.language = c("auto")
            // Inverse text normalization: punctuation and digits.
            config.model_config.sense_voice.use_itn = 1
            config.model_config.tokens = c(path("tokens.txt"))
        case .qwen3ASR:
            config.model_config.qwen3_asr.conv_frontend = c(path("conv_frontend.onnx"))
            config.model_config.qwen3_asr.encoder = c(path("encoder.int8.onnx"))
            config.model_config.qwen3_asr.decoder = c(path("decoder.int8.onnx"))
            config.model_config.qwen3_asr.tokenizer = c(path("tokenizer"))
        }

        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw OnDeviceASRError.modelLoadFailed
        }
        recognizer = r
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    /// Decode one complete utterance: 16 kHz mono float samples in [-1, 1].
    func recognize(samples: [Float]) -> String {
        guard !samples.isEmpty, let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return "" }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(stream, Int32(OnDeviceASRModel.sampleRate),
                                            buf.baseAddress, Int32(buf.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return "" }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let text = result.pointee.text else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var runtimeVersion: String { String(cString: SherpaOnnxGetVersionStr()) }

    /// Half the cores, at least 1, at most 4: an utterance is a few seconds of
    /// audio, and leaving cores free keeps the terminal (and ghostty's render
    /// threads) smooth while it decodes.
    static let defaultThreads: Int32 = {
        let n = ProcessInfo.processInfo.activeProcessorCount
        return Int32(max(1, min(4, n / 2)))
    }()
}

enum OnDeviceASRError: LocalizedError {
    case modelLoadFailed
    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Speech model couldn't load — download it again in Settings → Voice."
        }
    }
}
