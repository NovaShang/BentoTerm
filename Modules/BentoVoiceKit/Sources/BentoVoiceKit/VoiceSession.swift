import Foundation
import BentoFoundationKit

/// Shared voice-recording driver: engine selection (Apple on-device / OpenAI
/// realtime), permission gating, audio capture, and start/stop. The platform
/// controllers (iOS `VoiceInputController`, macOS `MacVoiceController`) wrap this
/// and add the gesture, the compass direction, haptics, and the overlay — so the
/// gnarly engine code lives in exactly one place.
@MainActor
public final class VoiceSession {
    private let audioCapture = AudioCaptureService()
    private var realtime: RealtimeASR?
    private var apple: AppleSpeechEngine?
    private var engine: SpeechEngineKind = .apple
    /// Sample rate the active realtime engine (and thus mic capture + the batch
    /// fallback) uses — OpenAI = 24 kHz, Qwen = 16 kHz. Set when a realtime
    /// session begins so `takeRecordedPCM`/batch wrap the clip at the right rate.
    private var activeSampleRate: Double = OpenAIRealtimeASRService.requiredSampleRate
    /// The Qwen context-biasing corpus assembled when this recording began, reused
    /// for the batch fallback so it biases the same way. Empty for non-Qwen.
    private var activeCorpus = ""

    /// The most recent transcript seen (so `finish()` can return the final text
    /// even for the OpenAI engine, whose final arrives via a callback).
    private var lastTranscript = ""
    public private(set) var isActive = false

    /// Incremented on every `start()`. The permission slow-path Task captures
    /// the value it was spawned under and bails if the session ended (or a
    /// newer one began) while the system permission dialog was up — a late
    /// grant must never fire an engine for a session that's already gone,
    /// which would stack a second mic tap on the input bus.
    private var sessionGeneration = 0

    /// Wall-clock of the last streamed interim. Lets `finish()` tell "spoke, then
    /// released" (interim has settled → send it immediately) from "released mid-
    /// speech" (wait briefly for the tail). nil until the first interim arrives.
    private var lastInterimAt: Date?

    /// The transcript streamed so far this session — read by the right-swipe
    /// preview to seed its editor while the batch model re-transcribes.
    public var currentTranscript: String { lastTranscript }

    /// Supplies the active pane's recent on-screen text for Qwen context biasing
    /// (set by the platform controller, which owns the terminal surface). Called
    /// synchronously on the main actor when a Qwen recording begins; nil = no
    /// auto-context (manual vocab only). Only the Qwen engine uses this.
    public var contextProvider: (() -> String?)?

    /// Set when the realtime engine delivers a non-empty final / emits its
    /// `completed` event after a commit — so `finish()` stops waiting promptly.
    private var realtimeFinalArrived = false
    private var realtimeCompleted = false

    /// Set by `cancel()`: the session was torn down mid-`finish()` (the error
    /// path). A cancelled session must resolve empty — otherwise the batch
    /// fallback would transcribe the clip and insert text right after the user
    /// saw an error. Reset on every `start()`.
    private var interrupted = false

    /// PCM captured before the realtime socket is open, flushed once it connects
    /// so the opening words aren't lost to the (cold) WSS handshake latency.
    private var pendingPCM: [Data] = []
    private var realtimeReady = false

    /// Energy gate between the mic and the realtime model. Until a chunk
    /// crosses the speech threshold, NOTHING is sent upstream — a silent hold
    /// otherwise makes the model hallucinate (it "transcribes" the biasing
    /// corpus, or invents stage directions like "(尴尬的沉默)"). See SpeechGate.
    private var speechGate = SpeechGate(sampleRate: OpenAIRealtimeASRService.requiredSampleRate)

    /// The whole utterance's PCM, accumulated across the entire recording (OpenAI
    /// engine only — Apple's engine captures audio internally and never hits
    /// `audioCapture`). The right-swipe preview flow grabs this after `stop()` to
    /// re-transcribe the full clip with a higher-accuracy batch model.
    private var recordedPCM = Data()

    /// Ceiling on the locally buffered full clip (~5 min of 24 kHz 16-bit mono
    /// ≈ 48 KB/s). Past it, PCM keeps streaming to the realtime engine but stops
    /// being buffered — a right-swipe/batch re-transcription of an hours-long
    /// hold would otherwise POST a huge base64 WAV. Full-clip capture is
    /// deliberate (right-swipe re-transcription); this only adds the ceiling.
    private static let recordedPCMMaxBytes = 14_400_000

    /// True once the local buffer hit `recordedPCMMaxBytes` — the buffered PCM is
    /// a truncated prefix, so the batch paths treat it as "nothing captured"
    /// rather than transcribing a partial clip.
    private var recordedPCMOverflowed = false

    public init() {}

    /// Pre-allocate the mic engine ahead of an imminent recording (e.g. the right
    /// button just went down) so the actual `start()` reaches the mic in a few ms
    /// instead of paying the cold-start tax. Cheap, idempotent, no mic indicator.
    public func prewarm() {
        audioCapture.prewarm()
    }

    /// Begin recording after ensuring permissions. `onPartial` streams the live
    /// transcript on the main actor; `onError` reports a user-facing message.
    public func start(onPartial: @escaping @MainActor (String) -> Void,
                      onError: @escaping @MainActor (String) -> Void) {
        // Defensive: never overlap sessions. If a prior recording is still active
        // (e.g. a failed one a caller didn't stop), tear it down first so we don't
        // leave a second mic engine / ASR socket running.
        if isActive { cancel() }
        engine = .current()
        sessionGeneration += 1
        isActive = true
        lastTranscript = ""
        lastInterimAt = nil
        recordedPCM = Data()
        recordedPCMOverflowed = false
        realtimeFinalArrived = false
        realtimeCompleted = false
        interrupted = false
        dlog("[voice] start engine=\(engine)")

        // Fast path: when permission is already granted (the common case after the
        // first grant), begin the engine INLINE on this main-actor turn — no Task
        // hop, no async permission round-trip — so the mic goes live immediately
        // instead of a few hundred ms after the compass appears.
        let needsSpeech = (engine == .apple)
        if MicPermission.micAuthorizedSync(), !needsSpeech || MicPermission.speechAuthorizedSync() {
            dlog("[voice] permission pre-granted → begin \(engine) inline")
            switch engine {
            case .apple:         beginApple(onPartial: onPartial, onError: onError)
            case .openai, .qwen: beginRealtime(onPartial: onPartial, onError: onError)
            }
            return
        }

        // Slow path: permission not yet determined — request it, then begin.
        let generation = sessionGeneration
        Task {
            guard await MicPermission.ensureMic() else {
                dlog("[voice] mic permission DENIED")
                isActive = false; onError("Microphone permission denied"); return
            }
            if engine == .apple, await MicPermission.ensureSpeech() == false {
                dlog("[voice] speech permission DENIED")
                isActive = false; onError("Speech recognition permission denied"); return
            }
            // The user may have released (finish/cancel) or started a newer
            // session while the dialog was up — a late grant must not fire an
            // engine for a session that's gone.
            guard isActive, generation == sessionGeneration else {
                dlog("[voice] session ended while awaiting permission — bailing")
                return
            }
            dlog("[voice] permissions ok → begin \(engine)")
            switch engine {
            case .apple:         beginApple(onPartial: onPartial, onError: onError)
            case .openai, .qwen: beginRealtime(onPartial: onPartial, onError: onError)
            }
        }
    }

    /// Quiet the interim must have been at release to treat it as the complete
    /// utterance — i.e. the user finished speaking, *then* released. Below this the
    /// release looks mid-word, so we still wait briefly for the tail.
    private static let settleThresholdMs: Double = 300
    /// Bounded wait for the tail when released mid-speech (down from 800 — we only
    /// pay it in the uncommon mid-speech case now, not on every send).
    private static let tailGraceMs = 300

    /// Milliseconds since the last streamed interim (∞ if none arrived).
    private var quietMs: Double {
        guard let t = lastInterimAt else { return .infinity }
        return Date().timeIntervalSince(t) * 1000
    }
    /// The streamed transcript is non-empty and has stopped changing → it already
    /// holds the whole utterance, so there's nothing to wait for.
    private var interimSettled: Bool {
        !lastTranscript.isEmpty && quietMs >= Self.settleThresholdMs
    }

    /// Stop recording and resolve the BEST final transcript.
    ///
    /// Adaptive: if the streamed interim has already settled (the user spoke, then
    /// released), it IS the final — return it immediately, no round-trip, so the
    /// common case sends instantly. Only when the release looks mid-speech do we
    /// wait a short grace for the tail, falling back to a whole-clip batch
    /// transcription if streaming caught nothing. `language` is the batch hint.
    public func finish(language: String) async -> String {
        isActive = false
        // The overlay now leaves on release, so the user can start a NEW hold
        // while this one is still resolving. Everything below the awaits is
        // therefore generation-checked: a stale finish must not read the new
        // recording's transcript, and above all must not null out its socket.
        let generation = sessionGeneration
        // A cancel() (error path) may have torn the session down before we got
        // here — a cancelled session resolves empty, never with text.
        guard !interrupted else { return "" }
        // Qwen's interims are a rolling window (they reset mid-utterance), NOT the
        // full running transcript, so a settled interim is not the final — force
        // the commit + wait path so we return the authoritative `completed`.
        // OpenAI's interim IS the full transcript, so a settled one ships instantly.
        let settled = interimSettled && engine != .qwen
        switch engine {
        case .apple:
            // Settled partial → return it now (non-awaiting stop); otherwise await
            // the on-device final (bounded internally) to catch the tail.
            if settled {
                let t = apple?.stopRecording() ?? lastTranscript
                apple = nil
                return t.isEmpty ? lastTranscript : t
            }
            let final = await apple?.finishRecording() ?? lastTranscript
            apple = nil
            return final.isEmpty ? lastTranscript : final

        case .openai, .qwen:
            audioCapture.stop()
            let asr = realtime
            // Silent (or near-silent) hold: the gate never opened, or it opened
            // on a blip and there was never enough speech to transcribe. Don't
            // commit — forcing a model to transcribe nothing is what produced
            // the corpus-echo / "(尴尬的沉默)" hallucinations — and don't
            // batch-transcribe it either. Just end empty.
            if !speechGate.isOpen || speechGate.voicedDuration < Self.minVoicedSeconds {
                dlog("[voice] not enough speech during hold (maxRMS=\(Int(speechGate.maxRMS)), voiced=\(String(format: "%.2f", speechGate.voicedDuration))s) — empty result")
                realtime = nil
                realtimeReady = false
                pendingPCM = []
                Task { await asr?.cancel() }
                return ""
            }
            // Fast path (OpenAI only): interim already complete → send it, tidy the
            // socket in the background. No commit, no wait, no "识别中".
            if settled {
                let streamed = lastTranscript
                realtime = nil
                realtimeReady = false
                pendingPCM = []
                Task { await asr?.cancel() }
                return isHallucinated(streamed) ? "" : streamed
            }
            // Released mid-speech (or Qwen, always): commit the buffer and wait
            // (bounded) for the realtime final. The socket stays open during this
            // so the `completed` event is processed (updates lastTranscript). Qwen's
            // final lands ~0.3–0.6s after commit, so it gets a longer grace.
            let graceMs = engine == .qwen ? 2000 : Self.tailGraceMs
            await asr?.commit()
            await waitForRealtimeFinal(graceMs: graceMs)
            // A newer recording began while we waited: its state has replaced
            // ours, so there is nothing of this utterance left to resolve — and
            // the teardown below would rip the socket out from under it.
            guard generation == sessionGeneration else {
                await asr?.cancel()
                return ""
            }
            let streamed = lastTranscript
            await asr?.cancel()
            realtime = nil
            realtimeReady = false
            pendingPCM = []
            // The session may have been cancelled (error) while we awaited the
            // final — resolve empty, never text right after the user saw an error.
            guard !interrupted else { return "" }
            if !streamed.isEmpty { return isHallucinated(streamed) ? "" : streamed }
            // Realtime delivered nothing (short clip): batch-transcribe the full
            // captured clip so the utterance is never lost. A clip that hit the
            // accumulation ceiling is truncated — treat it as nothing captured.
            guard !recordedPCM.isEmpty, !recordedPCMOverflowed else { return "" }
            dlog("[voice] realtime empty → batch fallback (\(recordedPCM.count) bytes)")
            let clipSeconds = recordedDuration
            let corpus = activeCorpus
            let better = await BatchTranscriptionService.shared.transcribe(
                pcm: recordedPCM, sampleRate: activeSampleRate, language: language, corpus: corpus)
            // The batch model is biased by the same corpus and fails the same
            // way on a thin clip — this is the path that reaches it most often.
            guard let better,
                  !isHallucinated(better, clipSeconds: clipSeconds, corpus: corpus) else { return "" }
            return better
        }
    }

    /// Tear down immediately WITHOUT resolving a final transcript (cancel ↓ /
    /// error / right-swipe, which re-transcribes the clip itself / defensive
    /// re-entry). Preserves `recordedPCM` so a caller can still batch it.
    public func cancel() {
        interrupted = true
        switch engine {
        case .apple:
            _ = apple?.stopRecording()
            apple = nil
        case .openai, .qwen:
            audioCapture.stop()
            let asr = realtime
            realtime = nil
            realtimeReady = false
            pendingPCM = []
            Task { await asr?.cancel() }
        }
        isActive = false
    }

    // MARK: - Hallucination guards

    /// Least voiced audio an utterance must contain before we ask a model to
    /// transcribe it. Under this it is a blip — a click, a breath, the button
    /// coming up — and committing it is precisely what makes Qwen hand the
    /// biasing corpus back as if it had been spoken.
    private static let minVoicedSeconds: TimeInterval = 0.25

    /// Seconds of audio actually captured this recording.
    private var recordedDuration: TimeInterval {
        Double(recordedPCM.count) / (activeSampleRate * Double(MemoryLayout<Int16>.size))
    }

    private func isHallucinated(_ text: String) -> Bool {
        isHallucinated(text, clipSeconds: recordedDuration, corpus: activeCorpus)
    }

    /// The clip's length and corpus are passed in so a caller that awaits a slow
    /// batch transcription can capture them BEFORE the await — by the time it
    /// returns, a new recording may have replaced both.
    private func isHallucinated(_ text: String, clipSeconds: TimeInterval, corpus: String) -> Bool {
        isImplausibleTranscript(text, clipSeconds: clipSeconds, corpus: corpus)
    }

    /// Poll for the realtime final after a commit, up to `graceMs`. Returns as
    /// soon as the `completed` event arrives (the flags are set on the main actor
    /// by the ASR callbacks, which run while this awaits).
    private func waitForRealtimeFinal(graceMs: Int) async {
        let ticks = max(1, graceMs / 20)
        for _ in 0..<ticks {
            if realtimeFinalArrived || realtimeCompleted { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The complete recorded audio of the just-finished session as 16-bit mono
    /// PCM + its sample rate, for the right-swipe batch re-transcription. Survives
    /// `stop()` (cleared on the next `start()`). Nil when no PCM was captured —
    /// e.g. the Apple on-device engine, which records internally.
    public func takeRecordedPCM() -> (pcm: Data, sampleRate: Double)? {
        guard !recordedPCM.isEmpty, !recordedPCMOverflowed else { return nil }
        // A clip with no real speech in it would only make the batch model
        // hallucinate in the preview editor — treat it as "nothing captured".
        guard speechGate.isOpen, speechGate.voicedDuration >= Self.minVoicedSeconds else { return nil }
        return (recordedPCM, activeSampleRate)
    }

    /// Batch-refine the just-captured PCM (if any). Returns true if a refinement
    /// Task was started (caller shows its loading state); completion delivers the
    /// higher-accuracy transcript (nil/empty = keep the streamed text).
    public func refineRecordedPCM(screenText: String?,
                                  completion: @escaping @MainActor (String?) -> Void) -> Bool {
        guard let rec = takeRecordedPCM() else { return false }
        let corpus = assembleQwenCorpus(screenText: screenText)
        let clipSeconds = recordedDuration
        Task {
            let lang = openAILanguageHint(for: UserDefaults.standard.string(forKey: "speech_locale") ?? "auto")
            let better = await BatchTranscriptionService.shared.transcribe(
                pcm: rec.pcm, sampleRate: rec.sampleRate, language: lang, corpus: corpus)
            // Same guard as the send path: a corpus echo must not land in the
            // preview editor either, where it reads as "this is what you said".
            await MainActor.run {
                completion(better.flatMap {
                    self.isHallucinated($0, clipSeconds: clipSeconds, corpus: corpus) ? nil : $0
                })
            }
        }
        return true
    }

    // MARK: - Apple (on-device)

    private func beginApple(onPartial: @escaping @MainActor (String) -> Void,
                            onError: @escaping @MainActor (String) -> Void) {
        guard isActive else { return }
        let eng = AppleSpeechEngine()
        apple = eng
        Task {
            do {
                try await eng.startRecording { partial in
                    Task { @MainActor in
                        self.lastTranscript = partial; self.lastInterimAt = Date(); onPartial(partial)
                    }
                }
                dlog("[voice] apple startRecording returned ok")
            } catch {
                dlog("[voice] apple startRecording FAILED: \(error.localizedDescription)")
                await MainActor.run { onError(error.localizedDescription) }
            }
        }
    }

    // MARK: - Realtime (OpenAI gpt-realtime-whisper / Qwen qwen3-asr-flash-realtime)

    private func beginRealtime(onPartial: @escaping @MainActor (String) -> Void,
                               onError: @escaping @MainActor (String) -> Void) {
        guard isActive else { return }
        let generation = sessionGeneration   // for the WSS connect Task below
        let defaults = UserDefaults.standard
        // Empty hint = auto-detect, which is best for 中英混说 on both engines.
        let language = openAILanguageHint(for: defaults.string(forKey: "speech_locale") ?? "auto")
        activeCorpus = ""

        let asr: RealtimeASR
        switch engine {
        case .qwen:
            // BYOK via a DashScope key; otherwise the bundled relay proxy (key
            // injected server-side, zero-config).
            let key = (defaults.string(forKey: "dashscope_api_key") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let proxyURL: URL? = key.isEmpty ? QwenRealtimeASRService.defaultProxyURL : nil
            activeCorpus = assembleQwenCorpus(screenText: contextProvider?())
            asr = QwenRealtimeASRService(apiKey: key, proxyURL: proxyURL, language: language, corpus: activeCorpus)
            dlog("[voice] qwen begin: byok=\(!key.isEmpty) proxy=\(proxyURL != nil) lang=\(language.isEmpty ? "auto" : language) corpus=\(activeCorpus.count)c")
        default: // .openai
            let key = (defaults.string(forKey: "openai_api_key") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let proxyURL: URL? = key.isEmpty ? OpenAIRealtimeASRService.defaultProxyURL : nil
            asr = OpenAIRealtimeASRService(apiKey: key, proxyURL: proxyURL, language: language)
            dlog("[voice] openai begin: byok=\(!key.isEmpty) proxy=\(proxyURL != nil) lang=\(language.isEmpty ? "auto" : language)")
        }
        realtime = asr
        activeSampleRate = asr.sampleRate
        pendingPCM = []
        realtimeReady = false
        speechGate = SpeechGate(sampleRate: asr.sampleRate)

        asr.onInterim = { text in Task { @MainActor in
            self.lastTranscript = text; self.lastInterimAt = Date(); onPartial(text)
        } }
        asr.onFinal = { text in Task { @MainActor in
            self.lastTranscript = text; self.realtimeFinalArrived = true; onPartial(text)
        } }
        asr.onCompleted = { Task { @MainActor in self.realtimeCompleted = true } }
        asr.onError = { err in
            dlog("[voice] realtime asr error: \(err.localizedDescription)")
            Task { @MainActor in onError(err.localizedDescription) }
        }
        // Buffer audio captured before the socket is open; flush on connect.
        // Everything is recorded locally, but only chunks the speech gate
        // admits go upstream — silence never reaches the model.
        audioCapture.onPCM = { [weak self, weak asr] pcm in
            Task { @MainActor in
                guard let self else { return }
                if self.recordedPCM.count < Self.recordedPCMMaxBytes {
                    self.recordedPCM.append(pcm)   // full clip for the right-swipe batch path
                } else {
                    self.recordedPCMOverflowed = true
                }
                let wasOpen = self.speechGate.isOpen
                let admitted = self.speechGate.admit(pcm)
                if !wasOpen, self.speechGate.isOpen {
                    dlog("[voice] speech gate OPEN (rms=\(Int(SpeechGate.rms16(pcm))), pre-roll=\(admitted.count - 1) chunks)")
                }
                guard !admitted.isEmpty else { return }
                if self.realtimeReady { for p in admitted { await asr?.sendAudio(p) } }
                else { self.pendingPCM.append(contentsOf: admitted) }
            }
        }

        // Start the mic immediately so the opening words are captured while the
        // (slower) WSS handshake runs.
        do {
            try audioCapture.start(targetSampleRate: asr.sampleRate)
            dlog("[voice] mic capture started @\(Int(asr.sampleRate))Hz")
        } catch {
            dlog("[voice] mic capture FAILED: \(error.localizedDescription)")
            onError(error.localizedDescription)
        }
        Task {
            // Session may have ended (or a newer one begun) while the socket
            // was connecting — don't mark the new session ready or flush its
            // buffered audio into this stale socket.
            guard isActive, generation == sessionGeneration else { return }
            do {
                try await asr.start()
                realtimeReady = true
                let buffered = pendingPCM
                pendingPCM = []
                dlog("[voice] realtime WSS connected; flushing \(buffered.count) buffered chunks")
                for pcm in buffered { await asr.sendAudio(pcm) }
            } catch {
                dlog("[voice] realtime WSS start FAILED: \(error.localizedDescription)")
                await MainActor.run { onError(error.localizedDescription) }
            }
        }
    }
}

// MARK: - Transcript sanity

/// Ceiling on how much text a hold can plausibly contain. Fast English runs
/// ~20 chars/s and Mandarin well under 10; a corpus echo lands in the hundreds,
/// so this only ever catches the impossible.
let maxTranscriptCharsPerSecond: Double = 30
/// Only short holds are checked against the corpus — that is where the model has
/// too little acoustic evidence and falls back on its context. On a normal-length
/// utterance, matching corpus text is far more likely to be the user genuinely
/// reading something off their screen.
let corpusEchoWindowSeconds: TimeInterval = 2.5
/// How much verbatim corpus text has to come back before it counts as an echo.
/// Kept high enough that dictating a short command that happens to be on screen
/// ("npm run build") still goes through.
let minCorpusEchoChars = 16

/// Is this "transcript" something the audio cannot have said?
///
/// Qwen — any context-biased ASR, really — does not answer "I heard nothing".
/// Starved of acoustic evidence it reaches for the context we handed it and
/// returns the biasing corpus, verbatim, as if it had been spoken; that text
/// used to go straight into the user's shell. Two structural tells, no model
/// involved: more text than the hold could physically contain, or a long
/// verbatim slice of our own corpus on a hold too short to have held it.
///
/// Free function on purpose — it is pure, and the failure it guards against is
/// worth testing without a live audio session.
func isImplausibleTranscript(_ text: String, clipSeconds: TimeInterval, corpus: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // No captured audio (Apple's engine records internally) → no duration to
    // judge against, so neither test applies.
    guard !t.isEmpty, clipSeconds > 0 else { return false }
    let seconds = max(clipSeconds, 0.2)
    if Double(t.count) / seconds > maxTranscriptCharsPerSecond {
        dlog("[voice] rejected hallucination: \(t.count) chars for \(String(format: "%.2f", seconds))s of audio")
        return true
    }
    guard seconds < corpusEchoWindowSeconds, !corpus.isEmpty else { return false }
    let key = corpusEchoKey(t)
    guard key.count >= minCorpusEchoChars, corpusEchoKey(corpus).contains(key) else { return false }
    dlog("[voice] rejected corpus echo (\(t.count) chars came back verbatim from the biasing corpus)")
    return true
}

/// Normalized form for the echo comparison: the model reflows whitespace and
/// re-punctuates what it echoes, so neither can be part of the match.
func corpusEchoKey(_ s: String) -> String {
    s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
}

/// Compass direction from a press-origin translation (points, y-down). Shared by
/// both platforms so the dead-zone + axis logic is identical.
public func voiceDirection(forTranslation t: CGSize, threshold: CGFloat = 40) -> VoiceDirection {
    let dx = t.width, dy = t.height
    if abs(dx) < threshold && abs(dy) < threshold { return .none }
    if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
    return dy < 0 ? .up : .down
}

// MARK: - Protocol seam for the shared controller

/// The slice of `VoiceSession` the shared `VoiceController` drives — protocol so
/// tests can inject a fake. Every member already exists on `VoiceSession` with
/// these exact signatures, so the conformance is a no-op.
@MainActor
public protocol VoiceSessionProtocol: AnyObject {
    var currentTranscript: String { get }
    var contextProvider: (() -> String?)? { get set }
    func prewarm()
    func start(onPartial: @escaping @MainActor (String) -> Void,
               onError: @escaping @MainActor (String) -> Void)
    func finish(language: String) async -> String
    func cancel()
    func refineRecordedPCM(screenText: String?,
                           completion: @escaping @MainActor (String?) -> Void) -> Bool
}

extension VoiceSession: VoiceSessionProtocol {}
