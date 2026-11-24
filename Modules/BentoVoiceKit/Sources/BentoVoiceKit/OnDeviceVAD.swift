import Foundation
import CoreML
import BentoFoundationKit
@preconcurrency import FluidAudio

/// Silero VAD as Core ML (FluidAudio's export) — what cuts a hold into speech
/// segments for the on-device engine, the way sherpa-onnx's simulated-
/// streaming example does for SenseVoice. It downloads with the speech model
/// (see `OnDeviceASRModel.senseVoiceSmall`).
///
/// A neural VAD rather than a loudness threshold because the two disagree
/// exactly where it matters: in quick, continuous speech the gaps between
/// phrases stay above any room-noise threshold, so a loudness cut never
/// comes and the open segment grows until a forced cut — the live text then
/// re-decodes a long stretch every tick and visibly jumps.
enum OnDeviceVAD {
    /// The bundle inside the model directory. Pinned with the download
    /// manifest, not taken from FluidAudio's `ModelNames`, so a FluidAudio
    /// bump can't point at a file we never downloaded.
    static let modelBundleName = "silero-vad-unified-256ms-v6.2.1.mlmodelc"

    static let sampleRate = 16_000
    /// The model scores fixed 256 ms windows; that is the VAD's resolution.
    static let chunkSamples = VadManager.chunkSize
    /// Silero's usual speech threshold (FluidAudio's default, 0.85, is tuned
    /// for long recordings and misses soft speech at the start of a hold).
    static let threshold: Float = 0.5
    /// One window below the (hysteresis) threshold closes a segment: short,
    /// so segments stay short and the live text has little to re-decode.
    static let minSilence: Double = 0
    static let minSpeech: Double = 0.25
    /// No pause for this long: close the segment anyway and start the next
    /// one where it ends.
    static let maxSpeech: Double = 8

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (path: String, model: MLModel)?

    /// The VAD model in `directory`, loaded once per process, on the CPU
    /// (~1 MB). A load blocks while Core ML loads anything else, so never call
    /// this on the main thread.
    static func model(in directory: URL) throws -> MLModel {
        let url = directory.appendingPathComponent(modelBundleName, isDirectory: true)
        lock.lock(); defer { lock.unlock() }
        if let c = cached, c.path == url.path { return c.model }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let m = try MLModel(contentsOf: url, configuration: config)
        cached = (url.path, m)
        return m
    }
}

/// One hold's VAD. An actor, so the main actor only hands it audio and gets
/// closed segments back.
actor OnDeviceSegmenter {
    struct Segment: Equatable {
        /// First sample, counted from the first sample ever fed.
        let start: Int
        let count: Int
    }

    private let vad: VadManager
    private let segmentation: VadSegmentationConfig
    private var state: VadStreamState
    /// Fed samples not yet scored (less than one window).
    private var pending: [Float] = []
    /// Where the open segment starts; nil when none is open.
    private var openStart: Int?
    private var fed = 0

    /// Throws when the VAD model isn't in `directory` or won't load; the
    /// session then cuts segments by loudness instead.
    init(directory: URL) throws {
        let model = try OnDeviceVAD.model(in: directory)
        vad = VadManager(config: VadConfig(defaultThreshold: OnDeviceVAD.threshold, computeUnits: .cpuOnly),
                         vadModel: model)
        segmentation = VadSegmentationConfig(
            minSpeechDuration: OnDeviceVAD.minSpeech,
            minSilenceDuration: OnDeviceVAD.minSilence,
            maxSpeechDuration: OnDeviceVAD.maxSpeech,
            speechPadding: 0.1)
        state = VadStreamState.initial()
    }

    /// Feed 16-bit 16 kHz PCM; returns the segments that closed and whether
    /// one is open now.
    func accept(pcm16 data: Data) async -> (segments: [Segment], speaking: Bool) {
        let segments = await accept(ASRPCM.floatSamples(int16LE: data))
        return (segments, openStart != nil)
    }

    /// Feed the last of the hold and close the open segment.
    func finish(pcm16 data: Data) async -> [Segment] {
        var out = await accept(ASRPCM.floatSamples(int16LE: data))
        if !pending.isEmpty {
            out += await score(pending)
            pending = []
        }
        if let start = openStart {
            openStart = nil
            out += keep(start, fed)
        }
        return out
    }

    /// Feed samples (mono, [-1, 1], 16 kHz) and take the segments that closed.
    func accept(_ samples: [Float]) async -> [Segment] {
        pending += samples
        var out: [Segment] = []
        let n = OnDeviceVAD.chunkSamples
        while pending.count >= n {
            let chunk = Array(pending.prefix(n))
            pending.removeFirst(n)
            out += await score(chunk)
        }
        return out
    }

    private func score(_ chunk: [Float]) async -> [Segment] {
        guard let result = try? await vad.processStreamingChunk(chunk, state: state, config: segmentation) else {
            fed += chunk.count
            return []
        }
        state = result.state
        fed = state.processedSamples
        var out: [Segment] = []
        if let event = result.event {
            switch event.kind {
            case .speechStart:
                openStart = max(event.sampleIndex, 0)
            case .speechEnd:
                if let start = openStart { out += keep(start, min(event.sampleIndex, fed)) }
                openStart = nil
            }
        }
        // No pause for too long: close here, keep going as a new segment.
        let maxSamples = Int(OnDeviceVAD.maxSpeech * Double(OnDeviceVAD.sampleRate))
        if let start = openStart, fed - start >= maxSamples {
            out += keep(start, fed)
            openStart = fed
        }
        return out
    }

    /// A segment, unless it is too short to be speech.
    private func keep(_ start: Int, _ end: Int) -> [Segment] {
        let count = end - start
        guard Double(count) >= OnDeviceVAD.minSpeech * Double(OnDeviceVAD.sampleRate) else { return [] }
        return [Segment(start: start, count: count)]
    }
}
