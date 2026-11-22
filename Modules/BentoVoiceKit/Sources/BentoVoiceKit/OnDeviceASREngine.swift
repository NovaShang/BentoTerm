import Foundation
import BentoFoundationKit
import CoreML
@preconcurrency import FluidAudio
#if os(iOS)
import UIKit
#endif

/// The on-device speech engine: SenseVoiceSmall as Core ML through FluidAudio
/// (the preprocessor on the CPU, the int8 encoder on the Neural Engine). One
/// lazily loaded model, kept warm between utterances. Only one model is
/// resident at a time — asking for another replaces it.
///
/// Loading (hundreds of ms the first time; Core ML caches the Neural Engine
/// plan after that) and resampling run on a serial queue, the decode on
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

    /// At launch: if the model is on disk but the Neural Engine copy isn't
    /// compiled for this OS build (first run after an OS update, or the app
    /// quit mid-compile), compile it now in the background so the next hold
    /// doesn't start on the slow CPU path. Doesn't keep the model loaded.
    public func compileForNeuralEngineIfNeeded(_ model: OnDeviceASRModel, directory: URL) {
        queue.async {
            let marker = directory.appendingPathComponent(Self.neuralEngineMarker)
            guard (try? String(contentsOf: marker, encoding: .utf8)) != Self.osBuild else { return }
            dlog("[on-device-asr] \(model.id) not compiled for the Neural Engine on this OS — compiling now")
            self.compileForNeuralEngine(model, directory, key: model.id + "|" + directory.path, marker: marker)
        }
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

    // MARK: Loading — CPU first, Neural Engine once it's compiled

    /// The Neural Engine is the fast path (a 3 s clip in ~25 ms on an M-series
    /// Mac, vs ~95 ms on the CPU), but Core ML compiles the int8 encoder for
    /// it the first time it's loaded from a given path, and that compile took
    /// ~2 minutes on an M-series Mac. Core ML caches the result, after which
    /// the load is ~200 ms.
    ///
    /// So: until a marker in the model directory says that compile finished
    /// (on this OS build — an OS update can drop the cache), the encoder loads
    /// on the CPU (~2 s the first time, then tens of ms) and the Neural Engine
    /// copy compiles in the background; when it's ready it replaces the CPU
    /// copy. Nobody waits two minutes for their first sentence.
    static let neuralEngineMarker = ".ane-compiled"
    private let warmQueue = DispatchQueue(label: "com.bento.voice.on-device-asr.ane", qos: .utility)
    // Queue-confined (`queue`).
    private var warmingKey: String?

    private static var osBuild: String { ProcessInfo.processInfo.operatingSystemVersionString }

    private func loadedManager(_ model: OnDeviceASRModel, _ dir: URL) throws -> SenseVoiceManager {
        let key = model.id + "|" + dir.path
        if let m = manager, loadedKey == key { return m }
        // Free the old one before loading: two models resident at once is
        // exactly the memory spike iOS kills apps for.
        manager = nil
        loadedKey = nil
        let marker = dir.appendingPathComponent(Self.neuralEngineMarker)
        let compiled = (try? String(contentsOf: marker, encoding: .utf8)) == Self.osBuild
        let t0 = Date()
        let m: SenseVoiceManager
        do {
            m = try Self.makeManager(model, dir, encoderUnits: compiled ? .cpuAndNeuralEngine : .cpuOnly)
        } catch {
            dlog("[on-device-asr] \(model.id) failed to load: \(error.localizedDescription)")
            throw OnDeviceASRError.modelLoadFailed
        }
        dlog("[on-device-asr] \(model.id) loaded in \(Int(Date().timeIntervalSince(t0) * 1000))ms on \(compiled ? "the Neural Engine" : "the CPU")")
        manager = m
        loadedKey = key
        if !compiled { compileForNeuralEngine(model, dir, key: key, marker: marker) }
        return m
    }

    /// Queue-confined. Load the Neural Engine copy in the background; swap it
    /// in if the same model is still the loaded one.
    private func compileForNeuralEngine(_ model: OnDeviceASRModel, _ dir: URL, key: String, marker: URL) {
        guard warmingKey != key else { return }
        warmingKey = key
        warmQueue.async {
            let t0 = Date()
            let fast = try? Self.makeManager(model, dir, encoderUnits: .cpuAndNeuralEngine)
            let seconds = Int(Date().timeIntervalSince(t0))
            self.queue.async {
                self.warmingKey = nil
                guard let fast else {
                    dlog("[on-device-asr] Neural Engine load failed after \(seconds)s — staying on the CPU")
                    return
                }
                try? Self.osBuild.write(to: marker, atomically: true, encoding: .utf8)
                dlog("[on-device-asr] compiled for the Neural Engine in \(seconds)s")
                if self.loadedKey == key { self.manager = fast }
            }
        }
    }

    /// FluidAudio's `SenseVoiceModels.load` fixes the encoder's compute units
    /// by precision; this is the same load with them chosen here. The
    /// preprocessor always runs on the CPU (fp32 — its power spectrum
    /// overflows fp16).
    private static func makeManager(_ model: OnDeviceASRModel, _ dir: URL,
                                    encoderUnits: MLComputeUnits) throws -> SenseVoiceManager {
        switch model.family {
        case .senseVoice:
            let cpu = MLModelConfiguration()
            cpu.computeUnits = .cpuOnly
            let encoderConfig = MLModelConfiguration()
            encoderConfig.computeUnits = encoderUnits
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
