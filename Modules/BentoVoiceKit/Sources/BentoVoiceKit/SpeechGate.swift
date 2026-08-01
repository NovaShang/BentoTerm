import Foundation

/// Energy gate between the mic and a realtime ASR model.
///
/// Streaming models transcribe whatever they're given — hand them a
/// silent hold and they hallucinate: with a context-biasing corpus they
/// "transcribe" the on-screen text, without one they emit stage directions
/// ("(尴尬的沉默)"). The root fix is to never let silence reach the model:
/// chunks stay gated until one crosses the speech RMS threshold, at which
/// point the gate opens for the rest of the session (mid-utterance pauses
/// must flow — the model's own context handles those fine).
///
/// While gated, recent chunks accumulate in a bounded pre-roll that is
/// flushed when the gate opens, so the onset syllable that *triggered* the
/// gate — and a beat before it — isn't clipped.
public struct SpeechGate {
    /// RMS (of Int16 samples) a chunk must reach to open the gate. Room tone
    /// on device mics with AGC sits well under 100; normal speech reaches
    /// several hundred to thousands. Deliberately low — a false-open costs a
    /// little hallucination risk, a false-closed costs the user's words.
    public let threshold: Double
    /// Cap on buffered pre-roll bytes (~0.6 s at the session sample rate).
    public let preRollCapBytes: Int

    public private(set) var isOpen = false
    /// Loudest chunk seen this session — logged at finish for threshold tuning.
    public private(set) var maxRMS: Double = 0

    private var preRoll: [Data] = []
    private var preRollBytes = 0

    public init(threshold: Double = 180, sampleRate: Double) {
        self.threshold = threshold
        self.preRollCapBytes = Int(sampleRate * 0.6) * MemoryLayout<Int16>.size
    }

    /// Feed one PCM chunk. Returns the chunks to forward to the ASR now:
    /// empty while gated, pre-roll + current on the opening chunk, and the
    /// chunk alone once open.
    public mutating func admit(_ pcm: Data) -> [Data] {
        if isOpen { return [pcm] }
        let level = Self.rms16(pcm)
        if level > maxRMS { maxRMS = level }
        if level >= threshold {
            isOpen = true
            let out = preRoll + [pcm]
            preRoll = []
            preRollBytes = 0
            return out
        }
        preRoll.append(pcm)
        preRollBytes += pcm.count
        while preRollBytes > preRollCapBytes, !preRoll.isEmpty {
            preRollBytes -= preRoll.removeFirst().count
        }
        return []
    }

    /// Root-mean-square of 16-bit little-endian mono samples. Unaligned loads —
    /// Data slices don't guarantee 2-byte alignment.
    public static func rms16(_ pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var acc = 0.0
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            for i in 0..<count {
                let v = Double(base.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                acc += v * v
            }
        }
        return (acc / Double(count)).squareRoot()
    }
}
