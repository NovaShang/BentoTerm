import Foundation
import AVFoundation

/// Captures microphone audio and emits 16-bit mono PCM chunks at a target rate
/// (OpenAI gpt-realtime-whisper wants 24 kHz). AVAudioEngine + AVAudioConverter
/// so output is independent of the hardware rate. Cross-platform — only the
/// AVAudioSession setup is iOS-specific (macOS has no session model).
public final class AudioCaptureService: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case converterUnavailable
        var errorDescription: String? { "Could not create audio converter." }
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    /// The input format the current `converter` was built from. The tap delivers
    /// the input node's live format, which can change between/within sessions
    /// (e.g. unplugging a display switches the audio route to a 24 kHz Bluetooth
    /// mic), so the converter is rebuilt whenever the incoming format changes.
    private var converterInputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat!
    private var targetRate: Double = 16000
    public private(set) var isRunning = false

    /// Called on the audio queue with each PCM chunk as it arrives.
    public var onPCM: (@Sendable (Data) -> Void)?

    public init() {}

    /// Pre-allocate the engine's resources WITHOUT going live, so the later
    /// `start()` reaches the mic in a few ms instead of paying the ~100-300ms
    /// cold-start tax. Called when a voice gesture is *likely* (e.g. the right
    /// button goes down) to overlap warm-up with the hold threshold the user is
    /// already waiting through. Never lights the mic indicator — only `start()`
    /// activates input. No-op once running.
    public func prewarm() {
        guard !isRunning else { return }
        #if os(iOS)
        // Pre-set the record category so start() skips the (re)configure cost.
        // Don't activate the session here — only `start()` goes live.
        try? AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
        #endif
        // Touch the input node so CoreAudio instantiates the HAL unit now, then
        // preallocate render resources. Both costs are otherwise paid on start().
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
    }

    public func start(targetSampleRate: Double = 16000) throws {
        // Never stack a second engine/tap on top of a running one: installing two
        // taps on the same input bus corrupts CoreAudio and hangs the main thread.
        // A prior session that failed without a clean stop must be torn down first.
        if isRunning { stop() }
        engine.inputNode.removeTap(onBus: 0)   // belt-and-suspenders: drop any stale tap
        self.targetRate = targetSampleRate
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
        #if os(iOS)
        // Mode parity with macOS: `.default` keeps the system's standard input
        // processing (AGC, noise handling), which is what Mac mics effectively
        // deliver at the driver level. `.measurement` opted OUT of all of it —
        // on an iPad's far-field mics that meant raw, quiet, noisier speech
        // than the Mac path ever saw. No `.duckOthers` either: the Mac doesn't
        // duck, and the audible dip made recordings feel different.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let input = engine.inputNode
        // Sanity-check the mic is ready (macOS can hand back a 0Hz/0ch format
        // before it is). Don't reuse this format for the tap, though — read it
        // again at the moment of install via `nil`.
        let nodeFormat = input.outputFormat(forBus: 0)
        guard nodeFormat.sampleRate > 0, nodeFormat.channelCount > 0 else {
            throw CaptureError.converterUnavailable
        }
        // Converter is built lazily in handleBuffer from the ACTUAL buffer format.
        converter = nil
        converterInputFormat = nil

        // Install with `nil` format → the tap uses the input node's LIVE format.
        // Passing an explicit (possibly stale) format crashes hard: when the
        // device switched samplerate (e.g. 48kHz → a 24kHz Bluetooth mic after a
        // display unplug), installTap throws an uncatchable ObjC exception
        // ("Format mismatch: input hw 24000 Hz, client format 48000 Hz") and the
        // app dies. nil can never mismatch.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handleBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
        converter = nil
        converterInputFormat = nil

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func handleBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let outputFormat else { return }
        // Build / rebuild the converter to match the ACTUAL incoming format. The
        // nil-format tap delivers the node's live format, which may differ from
        // what we saw at start() (or change mid-session on a route switch), so the
        // converter is always derived from the buffer in hand.
        if converter == nil || converterInputFormat != inputBuffer.format {
            converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat)
            converterInputFormat = inputBuffer.format
        }
        guard let converter else { return }
        let inputRate = inputBuffer.format.sampleRate
        let estFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * targetRate / inputRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estFrames) else {
            return
        }

        var error: NSError?
        var didProvide = false
        let status = converter.convert(to: outBuf, error: &error) { _, status in
            if didProvide {
                // `.noDataNow` (not `.endOfStream`): we've handed over this tap
                // buffer; the converter consumes it and stays usable for the next
                // buffer. `.endOfStream` would permanently end the (reused)
                // converter, so only the first 100ms ever converted.
                status.pointee = .noDataNow
                return nil
            }
            didProvide = true
            status.pointee = .haveData
            return inputBuffer
        }

        guard error == nil, status != .error else { return }
        guard let int16Ptr = outBuf.int16ChannelData?[0] else { return }

        let frames = Int(outBuf.frameLength)
        let byteCount = frames * MemoryLayout<Int16>.stride
        guard byteCount > 0 else { return }   // never emit an empty chunk (→ "invalid audio")
        let data = Data(bytes: int16Ptr, count: byteCount)
        onPCM?(data)
    }
}
