import Foundation
import BentoFoundationKit
@_implementationOnly import SherpaOnnxC

/// sherpa-onnx's voice activity detector running Silero VAD — what cuts a
/// hold into speech segments for the on-device engine, the way sherpa-onnx's
/// own simulated-streaming example does for SenseVoice.
///
/// A neural VAD rather than a loudness threshold because the two disagree
/// exactly where it matters: in quick, continuous speech the gaps between
/// phrases stay above any room-noise threshold, so a loudness cut never
/// comes and the open segment grows until a forced cut — the live text then
/// re-decodes a long stretch every tick and visibly jumps.
///
/// Not thread-safe; owned by one `OnDeviceSegmenter` and driven from its
/// serial queue.
final class SileroVAD {
    struct Segment {
        /// First sample, counted from the first sample ever fed.
        let start: Int
        let samples: [Float]
    }

    static let sampleRate = 16_000
    /// Pause that closes a segment, as in sherpa-onnx's example: short, so
    /// segments stay short and the live text has little to re-decode.
    static let minSilence: Float = 0.1
    static let minSpeech: Float = 0.25
    /// Past this the detector raises its threshold until a segment closes.
    static let maxSpeech: Float = 8

    private let vad: OpaquePointer
    private static let windowSize: Int32 = 512

    static var modelURL: URL? { Bundle.module.url(forResource: "silero_vad", withExtension: "onnx") }

    init() throws {
        guard let url = Self.modelURL else { throw OnDeviceASRError.modelLoadFailed }
        let path = strdup(url.path)!
        let provider = strdup("cpu")!
        defer { free(path); free(provider) }
        var config = SherpaOnnxVadModelConfig()
        config.silero_vad.model = UnsafePointer(path)
        config.silero_vad.threshold = 0.5
        config.silero_vad.min_silence_duration = Self.minSilence
        config.silero_vad.min_speech_duration = Self.minSpeech
        config.silero_vad.window_size = Self.windowSize
        config.silero_vad.max_speech_duration = Self.maxSpeech
        config.sample_rate = Int32(Self.sampleRate)
        config.num_threads = 1
        config.provider = UnsafePointer(provider)
        config.debug = 0
        // The detector buffers what it hasn't emitted; a hold is bounded by
        // the session's PCM ceiling, well under this.
        guard let p = SherpaOnnxCreateVoiceActivityDetector(&config, 600) else {
            throw OnDeviceASRError.modelLoadFailed
        }
        vad = p
    }

    deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }

    /// Feed samples (mono, [-1, 1], 16 kHz) and take the segments that closed.
    func accept(_ samples: [Float]) -> [Segment] {
        if !samples.isEmpty {
            samples.withUnsafeBufferPointer {
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, Int32($0.count))
            }
        }
        return drain()
    }

    /// The hold is over: close whatever segment is still open.
    func flush() -> [Segment] {
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        return drain()
    }

    /// Speech is going on right now (a segment is open).
    var isSpeaking: Bool { SherpaOnnxVoiceActivityDetectorDetected(vad) != 0 }

    private func drain() -> [Segment] {
        var out: [Segment] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            if let seg = SherpaOnnxVoiceActivityDetectorFront(vad) {
                let n = Int(seg.pointee.n)
                let samples = n > 0 && seg.pointee.samples != nil
                    ? Array(UnsafeBufferPointer(start: seg.pointee.samples, count: n)) : []
                out.append(Segment(start: Int(seg.pointee.start), samples: samples))
                SherpaOnnxDestroySpeechSegment(seg)
            }
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }
        return out
    }
}

/// One hold's VAD, confined to its own serial queue so the main actor only
/// hands it audio and gets closed segments back.
final class OnDeviceSegmenter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bento.voice.vad", qos: .userInitiated)
    private let vad: SileroVAD

    init() throws { vad = try SileroVAD() }

    /// Feed 16-bit 16 kHz PCM; returns the segments that closed and whether
    /// one is open now.
    func accept(pcm16 data: Data) async -> (segments: [SileroVAD.Segment], speaking: Bool) {
        await withCheckedContinuation { cont in
            queue.async {
                let segments = self.vad.accept(ASRPCM.floatSamples(int16LE: data))
                cont.resume(returning: (segments, self.vad.isSpeaking))
            }
        }
    }

    /// Feed the last of the hold and close the open segment.
    func finish(pcm16 data: Data) async -> [SileroVAD.Segment] {
        await withCheckedContinuation { cont in
            queue.async {
                let segments = self.vad.accept(ASRPCM.floatSamples(int16LE: data)) + self.vad.flush()
                cont.resume(returning: segments)
            }
        }
    }
}
