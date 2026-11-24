import Foundation
import BentoFoundationKit
import CoreML
@preconcurrency import FluidAudio
#if os(iOS)
import UIKit
#endif

/// The on-device speech engine: SenseVoiceSmall as Core ML through FluidAudio,
/// on the CPU (see `computeUnits`). One lazily loaded model, kept warm between utterances. Only one model is
/// resident at a time — asking for another replaces it.
///
/// Loading (~2 s the first time, ~10 ms after that) and resampling run on a serial queue, the decode on
/// FluidAudio's `SenseVoiceManager` actor — never on the main thread. Callers
/// `await` the result.
public final class OnDeviceASREngine: @unchecked Sendable {
    public static let shared = OnDeviceASREngine()

    private let queue = DispatchQueue(label: "com.bento.voice.on-device-asr", qos: .userInitiated)
    // Queue-confined.
    private var manager: SenseVoiceManager?
    private var loadedKey: String?

    /// SenseVoice's text-norm query: 14 = "withitn" (inverse text
    /// normalization: punctuation and digits). FluidAudio defaults to 15,
    /// "woitn", which leaves the text unpunctuated.
    static let withITN: Int32 = 14

    init() {
        #if os(iOS)
        // A loaded model holds hundreds of MB; give it back when iOS asks.
        // The next utterance reloads it.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil) { [weak self] _ in
                dlog("[on-device-asr] memory warning — unloading model")
                self?.unload()
            }
        #endif
    }

    /// Start loading the model now (e.g. when recording begins) so the
    /// decode after release doesn't pay for it. No-op if already loaded.
    public func preload(_ model: OnDeviceASRModel, directory: URL) {
        queue.async { _ = try? self.loadedManager(model, directory) }
    }

    /// Drop the loaded model (memory warning, model deleted).
    public func unload() {
        queue.async {
            self.manager = nil
            self.loadedKey = nil
        }
    }

    /// Transcribe a complete clip of 16-bit little-endian mono PCM.
    public func transcribe(pcm16 data: Data, sampleRate: Double,
                           model: OnDeviceASRModel, directory: URL) async throws -> String {
        let (m, samples) = try await onQueue {
            let samples = ASRPCM.resample(ASRPCM.floatSamples(int16LE: data),
                                          from: sampleRate, to: Double(OnDeviceASRModel.sampleRate))
            return (try self.loadedManager(model, directory), samples)
        }
        return try await decode(samples, with: m, model)
    }

    /// Transcribe float samples (any rate; resampled to 16 kHz).
    public func transcribe(samples: [Float], sampleRate: Double,
                           model: OnDeviceASRModel, directory: URL) async throws -> String {
        let (m, s) = try await onQueue {
            let s = ASRPCM.resample(samples, from: sampleRate, to: Double(OnDeviceASRModel.sampleRate))
            return (try self.loadedManager(model, directory), s)
        }
        return try await decode(s, with: m, model)
    }

    /// Under this the preprocessor has no whole 25 ms frame to work on.
    static let minSamples = 800

    private func decode(_ samples: [Float], with m: SenseVoiceManager,
                        _ model: OnDeviceASRModel) async throws -> String {
        guard samples.count >= Self.minSamples else { return "" }
        let t0 = Date()
        let text = try await m.transcribe(audio: samples).trimmingCharacters(in: .whitespacesAndNewlines)
        let audio = Double(samples.count) / Double(OnDeviceASRModel.sampleRate)
        dlog("[on-device-asr] \(model.family) decoded \(String(format: "%.2f", audio))s audio in \(Int(Date().timeIntervalSince(t0) * 1000))ms → \(text.count) chars")
        return text
    }

    // MARK: Loading

    /// CPU on purpose. Measured on an M-series Mac, one encoder pass over up
    /// to ~7 s of audio: CPU 75 ms, Neural Engine 17 ms, GPU 400 ms. The Neural
    /// Engine first needs a 2–4 minute compile (again after an OS update or a
    /// cache purge), and until it ends Core ML blocks every other model load
    /// in the process — a hold then froze the app. 75 ms fits the 350 ms
    /// live-text tick, so it isn't worth it.
    static let computeUnits: MLComputeUnits = .cpuOnly

    private func loadedManager(_ model: OnDeviceASRModel, _ dir: URL) throws -> SenseVoiceManager {
        let key = model.id + "|" + dir.path
        if let m = manager, loadedKey == key { return m }
        // Free the old one before loading: two models resident at once is
        // exactly the memory spike iOS kills apps for.
        manager = nil
        loadedKey = nil
        let t0 = Date()
        let m: SenseVoiceManager
        do {
            m = try Self.makeManager(model, dir)
        } catch {
            dlog("[on-device-asr] \(model.id) failed to load: \(error.localizedDescription)")
            throw OnDeviceASRError.modelLoadFailed
        }
        dlog("[on-device-asr] \(model.id) loaded in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        manager = m
        loadedKey = key
        return m
    }

    /// FluidAudio's `SenseVoiceModels.load` fixes the encoder's compute units
    /// by precision; this is the same load with them chosen here. The
    /// preprocessor always runs on the CPU (fp32 — its power spectrum
    /// overflows fp16).
    private static func makeManager(_ model: OnDeviceASRModel, _ dir: URL) throws -> SenseVoiceManager {
        switch model.family {
        case .senseVoice:
            let cpu = MLModelConfiguration()
            cpu.computeUnits = .cpuOnly
            let encoderConfig = MLModelConfiguration()
            encoderConfig.computeUnits = computeUnits
            let pre = try MLModel(contentsOf: dir.appendingPathComponent(OnDeviceASRModel.SenseVoiceFiles.preprocessor),
                                  configuration: cpu)
            let enc = try MLModel(contentsOf: dir.appendingPathComponent(OnDeviceASRModel.SenseVoiceFiles.encoder),
                                  configuration: encoderConfig)
            let vocab = try loadVocabulary(dir.appendingPathComponent(OnDeviceASRModel.SenseVoiceFiles.vocabulary))
            return SenseVoiceManager(models: SenseVoiceModels(preprocessor: pre, encoder: enc, vocabulary: vocab),
                                     language: SenseVoiceConfig.defaultLanguage, textNorm: withITN)
        }
    }

    /// vocab.json: a JSON array of SentencePiece pieces, index = token id.
    static func loadVocabulary(_ url: URL) throws -> [Int: String] {
        guard let pieces = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String] else {
            throw OnDeviceASRError.modelLoadFailed
        }
        var vocab: [Int: String] = [:]
        vocab.reserveCapacity(pieces.count)
        for (i, piece) in pieces.enumerated() { vocab[i] = piece }
        return vocab
    }

    private func onQueue<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { cont.resume(with: Result { try work() }) }
        }
    }
}

enum OnDeviceASRError: LocalizedError {
    case modelLoadFailed
    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Speech model couldn't load — download it again in Settings → Voice."
        }
    }
}

// MARK: - PCM helpers (pure)

enum ASRPCM {
    /// 16-bit little-endian PCM → floats in [-1, 1).
    static func floatSamples(int16LE data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let lo = UInt16(raw[2 * i]), hi = UInt16(raw[2 * i + 1])
                out[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768
            }
        }
        return out
    }

    /// Linear-interpolation resample. Mic capture already arrives at 16 kHz
    /// (AVAudioConverter in AudioCaptureService), so in the app this is
    /// normally the identity; it matters for audio from anywhere else.
    static func resample(_ x: [Float], from inRate: Double, to outRate: Double) -> [Float] {
        guard !x.isEmpty, inRate > 0, outRate > 0, inRate != outRate else { return x }
        let outCount = Int((Double(x.count) * outRate / inRate).rounded())
        guard outCount > 0 else { return [] }
        let step = inRate / outRate
        var out = [Float](repeating: 0, count: outCount)
        let last = x.count - 1
        for i in 0..<outCount {
            let pos = Double(i) * step
            let j = Int(pos)
            if j >= last { out[i] = x[last]; continue }
            let frac = Float(pos - Double(j))
            out[i] = x[j] + (x[j + 1] - x[j]) * frac
        }
        return out
    }

    /// Minimal RIFF/WAVE reader for 16-bit PCM (mono, or downmixed), for the
    /// fixture test and the command-line check. Returns nil for anything else.
    static func readWAV(_ data: Data) -> (samples: [Float], sampleRate: Double)? {
        let b = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o+1]) << 8 | Int(b[o+2]) << 16 | Int(b[o+3]) << 24 }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o+1]) << 8 }
        guard b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: b[8..<12], encoding: .ascii) == "WAVE" else { return nil }
        var o = 12
        var channels = 0, rate = 0, bits = 0, format = 0
        while o + 8 <= b.count {
            let id = String(bytes: b[o..<o+4], encoding: .ascii) ?? ""
            let size = u32(o + 4)
            let body = o + 8
            if id == "fmt ", body + 16 <= b.count {
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
            } else if id == "data" {
                guard format == 1 || format == 0xFFFE, bits == 16, channels > 0, rate > 0 else { return nil }
                let end = min(body + size, b.count)
                let mono = floatSamples(int16LE: Data(b[body..<end]))
                guard channels > 1 else { return (mono, Double(rate)) }
                let frames = mono.count / channels
                var mixed = [Float](repeating: 0, count: frames)
                for f in 0..<frames {
                    var s: Float = 0
                    for c in 0..<channels { s += mono[f * channels + c] }
                    mixed[f] = s / Float(channels)
                }
                return (mixed, Double(rate))
            }
            o = body + size + (size & 1)
        }
        return nil
    }
}
