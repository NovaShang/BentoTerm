import Foundation

// Shared voice-input types, lifted out of the iOS app so macOS + iOS use one
// engine. The gesture/overlay/haptics stay per-platform; everything here is
// platform-neutral. See docs/prd.md §3.2 (voice = the product's core gesture).

/// Direction the user moved from the press origin while dictating — the
/// "compass" that decides what happens to the transcript.
public enum VoiceDirection: String, Sendable {
    case none     // No significant movement — insert text only
    case up       // Insert text + newline (send command)
    case down     // Cancel
    case left     // LLM: convert to shell command
    case right    // LLM: convert to shell command + send
}

/// A finished voice utterance + the direction modifier chosen on release.
public struct VoiceInputResult: Sendable {
    public let text: String
    public let direction: VoiceDirection
    public init(text: String, direction: VoiceDirection) {
        self.text = text
        self.direction = direction
    }
}

/// Which ASR engine a recording uses, from the `speech_engine` user setting.
/// `openai` = OpenAI Realtime; `qwen` = Alibaba DashScope Qwen realtime (best
/// 中文 / 中英混说 accuracy), both streaming and driven through `RealtimeASR`.
///
/// Apple is the only engine that runs with no configuration — it is on-device,
/// so it is the default. The two cloud engines are bring-your-own-key: Bento
/// operates no server, so audio goes from this machine straight to the provider
/// on the user's own credentials, or it does not go at all.
public enum SpeechEngineKind: String, Sendable, CaseIterable {
    case apple, openai, qwen
    public static func current() -> SpeechEngineKind {
        let raw = UserDefaults.standard.string(forKey: "speech_engine") ?? "apple"
        return SpeechEngineKind(rawValue: raw) ?? .apple
    }

    /// UserDefaults key holding the user's own API key for this engine.
    /// nil = runs on-device and needs no credentials.
    public var apiKeyDefaultsKey: String? {
        switch self {
        case .apple:  return nil
        case .openai: return "openai_api_key"
        case .qwen:   return "dashscope_api_key"
        }
    }

    /// The key the user has stored for this engine ("" = none, on-device engines
    /// included).
    public var apiKey: String {
        guard let key = apiKeyDefaultsKey else { return "" }
        return (UserDefaults.standard.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// False when the engine needs a key the user has not supplied — it cannot
    /// transcribe anything and must not be reached for.
    public var isConfigured: Bool { apiKeyDefaultsKey == nil || !apiKey.isEmpty }

    /// Name of the credential this engine needs, for UI that has to say so.
    public var credentialName: String {
        switch self {
        case .apple:  return ""
        case .openai: return "OpenAI API key"
        case .qwen:   return "DashScope API key"
        }
    }

    /// User-facing explanation of why this engine cannot run right now, or nil
    /// when it can. Shown at the moment of selection AND raised instead of a
    /// recording, so nobody discovers the gap as a network error mid-utterance.
    public var unavailableReason: String? {
        guard !isConfigured else { return nil }
        #if os(iOS)
        let location = "Settings → Speech Recognition"
        #else
        let location = "Settings → Voice"
        #endif
        return "\(displayName) needs your own \(credentialName). Add it in \(location), or switch to Apple (on-device)."
    }

    public var displayName: String {
        switch self {
        case .apple:  return "Apple (on-device)"
        case .openai: return "OpenAI Realtime"
        case .qwen:   return "Qwen realtime"
        }
    }
}

/// A streaming realtime ASR engine (OpenAI or Qwen). `VoiceSession` drives any
/// conformer identically — start → sendAudio* → commit → cancel — and receives
/// results through the callbacks. Keeping this behind a protocol lets the two
/// dialects (different endpoints, wire shapes, and sample rates) share one
/// capture/lifecycle path.
public protocol RealtimeASR: AnyObject {
    /// Sample rate (Hz) the mic capture must feed this engine.
    var sampleRate: Double { get }
    /// Streamed partial transcript (may be a rolling window, engine-dependent).
    var onInterim: (@Sendable (String) -> Void)? { get set }
    /// Authoritative final transcript for the committed utterance.
    var onFinal: (@Sendable (String) -> Void)? { get set }
    /// Fired after a commit once the engine emits `completed`, even if empty —
    /// the cue for the caller to stop waiting on the realtime final.
    var onCompleted: (@Sendable () -> Void)? { get set }
    var onError: (@Sendable (Error) -> Void)? { get set }
    func start() async throws
    func sendAudio(_ pcm: Data) async
    func commit() async
    func cancel() async
}

/// Protocol for a streaming speech-recognition engine.
public protocol SpeechEngine: AnyObject {
    func startRecording(onPartialResult: @escaping @Sendable (String) -> Void) async throws
    func stopRecording() -> String?
    var isRecording: Bool { get }
}

public enum SpeechError: LocalizedError {
    case notAvailable
    case notAuthorized

    public var errorDescription: String? {
        switch self {
        case .notAvailable: return "Speech recognition is not available."
        case .notAuthorized: return "Speech recognition is not authorized."
        }
    }
}

/// Assemble the Qwen context-biasing corpus from the user's manual vocabulary
/// (`asr_vocab`) plus, when `asr_auto_context` is on, the given recent on-screen
/// text. Manual vocab is kept in full at the front; the screen text is tail-
/// trimmed so the most recent content wins. Kept SMALL on purpose: a large
/// corpus doesn't just risk DashScope's ~20k-char drop ceiling (over which the
/// request is silently dropped), it swamps the acoustic model — Qwen starts
/// mis-recognizing and echoing the corpus back. That is worse here than
/// anywhere: the screen text is raw terminal scrollback, so the "context" is
/// build logs, paths and code, which is the least prose-like thing you could
/// bias a speech model with. Shared by the realtime engine and the batch
/// re-transcription so both bias identically. Empty = no biasing.
public func assembleQwenCorpus(screenText: String?, maxChars: Int = 2000) -> String {
    let defaults = UserDefaults.standard
    let vocab = (defaults.string(forKey: "asr_vocab") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let autoOn = (defaults.object(forKey: "asr_auto_context") as? Bool) ?? true
    var screen = ""
    if autoOn, let text = screenText?.trimmingCharacters(in: .whitespacesAndNewlines) {
        screen = text
    }
    if vocab.isEmpty && screen.isEmpty { return "" }
    let budget = max(0, maxChars - vocab.count - 1)
    if screen.count > budget { screen = String(screen.suffix(budget)) }
    return [vocab, screen].filter { !$0.isEmpty }.joined(separator: "\n")
}

/// Map a `speech_locale` setting to OpenAI's ISO-639-1 hint ("" = auto).
public func openAILanguageHint(for locale: String) -> String {
    switch locale {
    case "zh-Hans", "zh-Hant", "zh": return "zh"
    case "en-US", "en-GB", "en": return "en"
    case "ja-JP", "ja": return "ja"
    default: return ""
    }
}
