import Foundation
import BentoFoundationKit

/// Shared voice-recording driver: engine selection (Qwen realtime /
/// SenseVoice / Apple), permission gating, audio capture, and start/stop. The platform
/// controllers (iOS `VoiceInputController`, macOS `MacVoiceController`) wrap this
/// and add the gesture, the compass direction, haptics, and the overlay — so the
/// gnarly engine code lives in exactly one place.
@MainActor
public final class VoiceSession {
    private let audioCapture = AudioCaptureService()
    private var realtime: RealtimeASR?
    private var apple: AppleSpeechEngine?
    private var engine: SpeechEngineKind = .apple
    /// Sample rate of this recording's captured PCM, so `takeRecordedPCM`/batch
    /// wrap the clip at the right rate. Set when a session begins.
    private var activeSampleRate: Double = QwenRealtimeASRService.requiredSampleRate
    /// The Qwen context-biasing corpus assembled when this recording began, reused
    /// for the batch fallback so it biases the same way. Empty for non-Qwen.
    private var activeCorpus = ""

    /// The most recent transcript seen (so `finish()` can return the final text
    /// even for the realtime engine, whose final arrives via a callback).
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

    /// Supplies what the terminal knows about the target pane (command, cwd,
    /// session, hosts) for the Apple engine's contextual strings. Called on
    /// the main actor when an Apple recording begins — a few property reads;
    /// `ContextVocabulary.gather` does the rest off the main thread.
    public var vocabularyProvider: (() -> VoiceContextSnapshot?)?

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
    private var speechGate = SpeechGate(sampleRate: QwenRealtimeASRService.requiredSampleRate)

    /// The whole utterance's PCM, accumulated across the entire recording
    /// (not Apple's engine — it captures audio internally and never hits
    /// `audioCapture`). The right-swipe preview flow grabs this after `stop()` to
    /// re-transcribe the full clip with a higher-accuracy batch model.
    private var recordedPCM = Data()

    /// Ceiling on the locally buffered full clip (~7 min of 16 kHz 16-bit mono
    /// ≈ 32 KB/s). Past it, PCM keeps streaming to the realtime engine but stops
    /// being buffered — a right-swipe/batch re-transcription of an hours-long
    /// hold would otherwise POST a huge base64 WAV. Full-clip capture is
    /// deliberate (right-swipe re-transcription); this only adds the ceiling.
    private static let recordedPCMMaxBytes = 14_400_000

    /// True once the local buffer hit `recordedPCMMaxBytes` — the buffered PCM is
    /// a truncated prefix, so the batch paths treat it as "nothing captured"
    /// rather than transcribing a partial clip.
    private var recordedPCMOverflowed = false

    /// Simulated streaming for the on-device engine (see `partialTick`).
    private var partialTask: Task<Void, Never>?
    private var partialDecodeInFlight = false
    private var partialDecodedBytes = 0
    /// Audio before this byte offset has been cut into segments at pauses and
    /// decoded once; `committedText` is what they said. Never re-decoded, so
    /// what is on screen up to there stops changing.
    private var committedBytes = 0
    private var committedText = ""
    /// The hold's voice activity detector (nil if its model won't load —
    /// then segments are cut by loudness instead), and how much of the clip
    /// it has been fed.
    private var segmenter: OnDeviceSegmenter?
    private var vadFedBytes = 0

    /// Test seam: a fixed model store for every on-device engine. nil = the
    /// shared per-model stores the Settings panel drives.
    private let modelStoreOverride: OnDeviceModelStore?

    public init(modelStore: OnDeviceModelStore? = nil) {
        self.modelStoreOverride = modelStore
    }

    /// The store (location + readiness) of the on-device model this recording
    /// uses; nil for streaming engines.
    private var activeModelStore: OnDeviceModelStore? {
        guard let model = engine.onDeviceModel else { return nil }
        return modelStoreOverride ?? OnDeviceModelStore.shared(for: model)
    }

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
        // On-device model engine picked but its model isn't on the device (or
        // is still downloading): say so on the gesture and record nothing. No
        // fallback to another engine — that would make the choice look ignored.
        if let store = activeModelStore {
            if !store.state.isInstalled { store.refresh() }
            if let message = onDeviceModelUnavailableMessage(for: store.state) {
                dlog("[voice] \(engine) unavailable: \(message)")
                isActive = false
                onError(message)
                return
            }
        }
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
        let needsSpeech = engine == .apple
        if MicPermission.micAuthorizedSync(), !needsSpeech || MicPermission.speechAuthorizedSync() {
            dlog("[voice] permission pre-granted → begin \(engine) inline")
            begin(onPartial: onPartial, onError: onError)
            return
        }

        // Slow path: permission not yet determined — request it, then begin.
        let generation = sessionGeneration
        Task {
            guard await MicPermission.ensureMic() else {
                dlog("[voice] mic permission DENIED")
                isActive = false; onError("Microphone permission denied"); return
            }
            if needsSpeech, await MicPermission.ensureSpeech() == false {
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
            begin(onPartial: onPartial, onError: onError)
        }
    }

    private func begin(onPartial: @escaping @MainActor (String) -> Void,
                       onError: @escaping @MainActor (String) -> Void) {
        switch engine {
        case .apple:      beginApple(vocabulary: makeVocabularyTask(), onPartial: onPartial, onError: onError)
        case .qwen:       beginRealtime(onPartial: onPartial, onError: onError)
        case .senseVoice: beginOnDevice(onPartial: onPartial, onError: onError)
        }
    }

    /// The pane snapshot is taken now (main actor, property reads); reading
    /// host aliases off disk and building the list happen off the main thread.
    private func makeVocabularyTask() -> Task<[String], Never> {
        let snapshot = vocabularyProvider?()
        return Task { await ContextVocabulary.gather(snapshot) }
    }

    /// Quiet the interim must have been at release to treat it as the complete
    /// utterance — i.e. the user finished speaking, *then* released. Below this the
    /// release looks mid-word, so we still wait briefly for the tail.
    private static let settleThresholdMs: Double = 300
    /// Bounded wait for Qwen's final after the commit; it lands in ~0.3–0.6 s.
    private static let finalGraceMs = 2000

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
    /// Apple: a settled interim (the user spoke, then released) IS the final, so
    /// it returns at once; only a mid-speech release waits for the tail.
    /// SenseVoice: decode what is still open. Qwen: commit and wait for the final,
    /// falling back to a whole-clip batch transcription if streaming caught
    /// nothing. `language` is the batch hint.
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
        switch engine {
        case .apple:
            return await finishApple(settled: interimSettled)

        case .senseVoice:
            return await finishOnDevice(generation: generation)

        case .qwen:
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
            // Commit the buffer and wait (bounded) for the realtime final. Qwen's
            // interims are a rolling window (they reset mid-utterance), so even a
            // settled one is not the final. The socket stays open during this so
            // the `completed` event is processed (updates lastTranscript).
            await asr?.commit()
            await waitForRealtimeFinal(graceMs: Self.finalGraceMs)
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
            guard let better = await BatchTranscriptionService.shared.transcribe(
                pcm: recordedPCM, sampleRate: activeSampleRate, language: language, corpus: corpus)
            else { return "" }
            // The batch model is biased by the same corpus and fails the same
            // way on a thin clip — this is the path that reaches it most often.
            guard !isHallucinated(better, clipSeconds: clipSeconds, corpus: corpus) else { return "" }
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
        case .qwen:
            audioCapture.stop()
            let asr = realtime
            realtime = nil
            realtimeReady = false
            pendingPCM = []
            Task { await asr?.cancel() }
        case .senseVoice:
            partialTask?.cancel()
            partialTask = nil
            audioCapture.stop()
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
        if let store = activeModelStore {
            // On-device: the "better model" IS the engine — decode the clip
            // once and fill the preview with it.
            let clipSeconds = recordedDuration
            let model = store.model, dir = store.directory
            Task {
                let text = try? await OnDeviceASREngine.shared.transcribe(
                    pcm16: rec.pcm, sampleRate: rec.sampleRate, model: model, directory: dir)
                completion(text.flatMap {
                    self.isHallucinated($0, clipSeconds: clipSeconds, corpus: "") ? nil : $0
                })
            }
            return true
        }
        let corpus = assembleQwenCorpus(screenText: screenText)
        let clipSeconds = recordedDuration
        Task {
            let lang = speechLanguageHint(for: UserDefaults.standard.string(forKey: "speech_locale") ?? "auto")
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

    /// Settled partial → return it now (non-awaiting stop); otherwise await
    /// the on-device final (bounded internally) to catch the tail.
    private func finishApple(settled: Bool) async -> String {
        if settled {
            let t = apple?.stopRecording() ?? lastTranscript
            apple = nil
            return t.isEmpty ? lastTranscript : t
        }
        let final = await apple?.finishRecording() ?? lastTranscript
        apple = nil
        return final.isEmpty ? lastTranscript : final
    }

    private func beginApple(vocabulary: Task<[String], Never>,
                            onPartial: @escaping @MainActor (String) -> Void,
                            onError: @escaping @MainActor (String) -> Void) {
        guard isActive else { return }
        let eng = AppleSpeechEngine()
        apple = eng
        Task {
            // Milliseconds: the snapshot was taken already, this is the
            // ~/.ssh/config read and the dedupe.
            let strings = await vocabulary.value
            // Released (or superseded) while the list was being built.
            guard apple === eng else { return }
            do {
                try await eng.startRecording(contextualStrings: strings) { partial in
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

    // MARK: - On-device model (SenseVoice): simulated streaming

    /// Record the clip locally (nothing leaves the device) and, while the user
    /// talks, re-decode what's been captured so far every
    /// `OnDevicePartialPolicy.tickInterval` so they see what the model
    /// understood — the offline model has no streaming mode of its own. The
    /// model starts loading now so neither the first partial nor the final
    /// waits for it.
    private func beginOnDevice(onPartial: @escaping @MainActor (String) -> Void,
                               onError: @escaping @MainActor (String) -> Void) {
        guard isActive, let store = activeModelStore else { return }
        let generation = sessionGeneration
        activeSampleRate = Double(OnDeviceASRModel.sampleRate)
        activeCorpus = ""
        speechGate = SpeechGate(sampleRate: activeSampleRate)
        partialDecodeInFlight = false
        partialDecodedBytes = 0
        committedBytes = 0
        committedText = ""
        vadFedBytes = 0
        do {
            segmenter = try OnDeviceSegmenter(directory: store.directory)
        } catch {
            segmenter = nil
            dlog("[voice] VAD unavailable (\(error.localizedDescription)) — cutting segments by loudness")
        }
        OnDeviceASREngine.shared.preload(store.model, directory: store.directory)
        audioCapture.onPCM = { [weak self] pcm in
            Task { @MainActor in
                guard let self else { return }
                if self.recordedPCM.count < Self.recordedPCMMaxBytes {
                    self.recordedPCM.append(pcm)
                } else {
                    self.recordedPCMOverflowed = true
                }
                // The gate only measures here: it is how a silent hold or a
                // click resolves empty instead of being decoded.
                _ = self.speechGate.admit(pcm)
            }
        }
        do {
            try audioCapture.start(targetSampleRate: activeSampleRate)
            dlog("[voice] on-device capture started @\(Int(activeSampleRate))Hz")
        } catch {
            dlog("[voice] mic capture FAILED: \(error.localizedDescription)")
            onError(error.localizedDescription)
            return
        }
        partialTask?.cancel()
        partialTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: OnDevicePartialPolicy.tickInterval)
                guard let self, self.isActive, generation == self.sessionGeneration else { return }
                self.partialTick(store: store, generation: generation, onPartial: onPartial)
            }
        }
    }

    /// One tick of the simulated stream. The offline model has no streaming
    /// mode, so each tick decodes audio again — but only the OPEN segment (the
    /// audio since the last pause), never the whole clip. When a pause closes
    /// the segment (or it runs too long without one), that stretch is decoded
    /// once and kept: the text before it stops changing, and each tick costs
    /// at most a segment's worth of decoding however long the hold.
    ///
    /// Main actor work is a decision and a copy of the open segment; the
    /// decodes run on the engine's serial queue.
    private func partialTick(store: OnDeviceModelStore, generation: Int,
                             onPartial: @escaping @MainActor (String) -> Void) {
        if let segmenter {
            partialTickByVAD(segmenter, store: store, generation: generation, onPartial: onPartial)
        } else {
            partialTickByLoudness(store: store, generation: generation, onPartial: onPartial)
        }
    }

    /// Segments closed by the VAD (one quiet 256 ms window, or 8 s without
    /// one) are decoded once and kept; while one is open, only it is decoded
    /// for the live text — the simulated streaming sherpa-onnx's SenseVoice
    /// example does.
    private func partialTickByVAD(_ segmenter: OnDeviceSegmenter, store: OnDeviceModelStore,
                                  generation: Int,
                                  onPartial: @escaping @MainActor (String) -> Void) {
        let total = recordedPCM.count & ~1
        guard !partialDecodeInFlight, speechGate.isOpen, total > vadFedBytes else { return }
        let fresh = recordedPCM.subdata(in: vadFedBytes..<total)
        vadFedBytes = total
        partialDecodeInFlight = true
        let rate = activeSampleRate
        let model = store.model, dir = store.directory
        Task { @MainActor [weak self] in
            let (segments, speaking) = await segmenter.accept(pcm16: fresh)
            guard let self, generation == self.sessionGeneration else { return }
            for segment in segments where segment.count > 0 {
                let range = OnDevicePartialPolicy.segmentBytes(
                    in: self.recordedPCM, start: segment.start, count: segment.count,
                    floor: self.committedBytes, sampleRate: rate)
                self.committedBytes = max(self.committedBytes, range.upperBound)
                let pcm = self.recordedPCM.subdata(in: range)
                do {
                    let text = try await OnDeviceASREngine.shared.transcribe(
                        pcm16: pcm, sampleRate: rate, model: model, directory: dir)
                    guard generation == self.sessionGeneration else { return }
                    self.committedText = OnDevicePartialPolicy.join(self.committedText, text)
                } catch {
                    dlog("[voice] on-device segment decode FAILED: \(error.localizedDescription)")
                }
            }
            var open = ""
            let end = min(self.vadFedBytes, self.recordedPCM.count & ~1)
            let start = min(self.committedBytes, end)
            if speaking, Double(end - start) >= OnDevicePartialPolicy.minAudioSeconds * rate * 2 {
                let tail = self.recordedPCM.subdata(in: start..<end)
                open = (try? await OnDeviceASREngine.shared.transcribe(
                    pcm16: tail, sampleRate: rate, model: model, directory: dir)) ?? ""
                guard generation == self.sessionGeneration else { return }
            }
            self.partialDecodeInFlight = false
            guard self.isActive else { return }
            let shown = OnDevicePartialPolicy.join(self.committedText, open)
            guard !shown.isEmpty else { return }
            self.lastTranscript = shown
            self.lastInterimAt = Date()
            onPartial(shown)
        }
    }

    /// Fallback when the VAD can't load: segments cut at quiet stretches.
    private func partialTickByLoudness(store: OnDeviceModelStore, generation: Int,
                                       onPartial: @escaping @MainActor (String) -> Void) {
        let total = recordedPCM.count & ~1   // whole samples only
        guard !partialDecodeInFlight, speechGate.isOpen, total > partialDecodedBytes,
              total > committedBytes else { return }
        let rate = activeSampleRate
        let open = recordedPCM.subdata(in: committedBytes..<total)
        var closing: Data?
        if let cut = OnDevicePartialPolicy.cut(open, sampleRate: rate) {
            if cut.voiced { closing = open.subdata(in: 0..<cut.offset) }
            committedBytes += cut.offset
        }
        let tail = recordedPCM.subdata(in: committedBytes..<total)
        let decodeTail = Double(tail.count) >= OnDevicePartialPolicy.minAudioSeconds * rate * 2
        partialDecodedBytes = total
        partialDecodeInFlight = true
        let model = store.model, dir = store.directory
        Task { @MainActor [weak self] in
            var closed = ""
            if let closing {
                do {
                    closed = try await OnDeviceASREngine.shared.transcribe(
                        pcm16: closing, sampleRate: rate, model: model, directory: dir)
                } catch {
                    dlog("[voice] on-device segment decode FAILED: \(error.localizedDescription)")
                }
            }
            let open = decodeTail ? (try? await OnDeviceASREngine.shared.transcribe(
                pcm16: tail, sampleRate: rate, model: model, directory: dir)) ?? "" : ""
            guard let self, generation == self.sessionGeneration else { return }
            self.committedText = OnDevicePartialPolicy.join(self.committedText, closed)
            self.partialDecodeInFlight = false
            guard self.isActive else { return }
            let shown = OnDevicePartialPolicy.join(self.committedText, open)
            guard !shown.isEmpty else { return }
            self.lastTranscript = shown
            self.lastInterimAt = Date()
            onPartial(shown)
        }
    }

    /// Stop the mic and decode what no tick has closed yet — the open segment —
    /// off the main thread, then put it after the segments already decoded.
    /// The final is therefore what was on screen plus its last words, rather
    /// than a fresh decode of the whole clip that could disagree with it.
    private func finishOnDevice(generation: Int) async -> String {
        partialTask?.cancel()
        partialTask = nil
        audioCapture.stop()
        // Chunks the tap delivered just before the stop are still queued as
        // main-actor tasks; let them land so the last syllable isn't cut.
        try? await Task.sleep(for: .milliseconds(40))
        // A new hold began in that window: the buffer is already its clip.
        guard generation == sessionGeneration else { return "" }
        guard speechGate.isOpen, speechGate.voicedDuration >= Self.minVoicedSeconds else {
            dlog("[voice] not enough speech during hold (maxRMS=\(Int(speechGate.maxRMS)), voiced=\(String(format: "%.2f", speechGate.voicedDuration))s) — empty result")
            return ""
        }
        // A tick may be closing a segment right now; its text belongs before
        // the tail. Bounded: past it, decode the whole clip as one.
        var waits = 0
        while partialDecodeInFlight, waits < 150 {
            try? await Task.sleep(for: .milliseconds(20))
            waits += 1
        }
        guard generation == sessionGeneration else { return "" }
        if let segmenter, !partialDecodeInFlight {
            return await finishByVAD(segmenter, generation: generation)
        }
        let whole = partialDecodeInFlight
        // Snapshot before the await: a new hold may start while this decodes,
        // and it resets the buffer. This utterance still gets its text.
        let total = recordedPCM.count & ~1
        let start = whole ? 0 : min(committedBytes, total)
        let pcm = recordedPCM.subdata(in: start..<total)
        let committed = whole ? "" : committedText
        let rate = activeSampleRate
        let clipSeconds = recordedDuration
        guard let store = activeModelStore else { return "" }
        let model = store.model, dir = store.directory
        do {
            let tail = pcm.count >= Int(rate * 0.1) * 2
                ? try await OnDeviceASREngine.shared.transcribe(
                    pcm16: pcm, sampleRate: rate, model: model, directory: dir)
                : ""
            let text = OnDevicePartialPolicy.join(committed, tail)
            if generation == sessionGeneration, interrupted { return "" }
            return isImplausibleTranscript(text, clipSeconds: clipSeconds, corpus: "") ? "" : text
        } catch {
            dlog("[voice] on-device decode FAILED: \(error.localizedDescription)")
            // Files that verified but won't load: forget the install so the
            // next hold says to download it again instead of failing silently.
            store.invalidate()
            return committed
        }
    }

    /// The VAD's final: feed it the rest of the clip, close the open segment,
    /// decode what closed and put it after the segments already kept.
    private func finishByVAD(_ segmenter: OnDeviceSegmenter, generation: Int) async -> String {
        let total = recordedPCM.count & ~1
        let fresh = recordedPCM.subdata(in: min(vadFedBytes, total)..<total)
        vadFedBytes = total
        let committed = committedText
        let clipSeconds = recordedDuration
        guard let store = activeModelStore else { return committed }
        let model = store.model, dir = store.directory
        // Snapshot: a new hold may start while this decodes and reset these.
        let clip = recordedPCM
        var floor = committedBytes
        let rate = activeSampleRate
        let segments = await segmenter.finish(pcm16: fresh)
        var text = committed
        for segment in segments where segment.count > 0 {
            let range = OnDevicePartialPolicy.segmentBytes(
                in: clip, start: segment.start, count: segment.count,
                floor: floor, sampleRate: rate)
            floor = max(floor, range.upperBound)
            do {
                let part = try await OnDeviceASREngine.shared.transcribe(
                    pcm16: clip.subdata(in: range), sampleRate: rate, model: model, directory: dir)
                text = OnDevicePartialPolicy.join(text, part)
            } catch {
                dlog("[voice] on-device decode FAILED: \(error.localizedDescription)")
                store.invalidate()
                return committed
            }
        }
        if generation == sessionGeneration, interrupted { return "" }
        return isImplausibleTranscript(text, clipSeconds: clipSeconds, corpus: "") ? "" : text
    }

    // MARK: - Realtime (Qwen qwen3-asr-flash-realtime)

    private func beginRealtime(onPartial: @escaping @MainActor (String) -> Void,
                               onError: @escaping @MainActor (String) -> Void) {
        guard isActive else { return }
        let generation = sessionGeneration   // for the WSS connect Task below
        let defaults = UserDefaults.standard
        // Empty hint = auto-detect, which is best for 中英混说.
        let language = speechLanguageHint(for: defaults.string(forKey: "speech_locale") ?? "auto")
        activeCorpus = assembleQwenCorpus(screenText: contextProvider?())
        let asr: RealtimeASR = QwenRealtimeASRService(apiKey: engine.apiKey(defaults: defaults),
                                                      language: language, corpus: activeCorpus)
        dlog("[voice] qwen begin: lang=\(language.isEmpty ? "auto" : language) corpus=\(activeCorpus.count)c")
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
    var vocabularyProvider: (() -> VoiceContextSnapshot?)? { get set }
    func prewarm()
    func start(onPartial: @escaping @MainActor (String) -> Void,
               onError: @escaping @MainActor (String) -> Void)
    func finish(language: String) async -> String
    func cancel()
    func refineRecordedPCM(screenText: String?,
                           completion: @escaping @MainActor (String?) -> Void) -> Bool
}

extension VoiceSession: VoiceSessionProtocol {}

// MARK: - Simulated streaming policy (on-device engines)

/// How a hold is cut into segments for live partials. Pure, so the rules are
/// testable without audio. The session decodes only the open segment each
/// tick and keeps a closed segment's text for good; it skips a tick while a
/// decode is running, when nothing new arrived, under ~0.3 s of audio, and
/// before the speech gate opens (decoding silence only invites junk).
///
/// It used to re-decode the whole clip every tick (a trailing 20 s window
/// past that): the model revised earlier words on every pass, and once the
/// window started sliding the whole line was replaced each time — long
/// dictation jumped about the screen.
enum OnDevicePartialPolicy {
    /// How often a partial is attempted while the user talks. The knob to
    /// tune: lower = livelier text, more CPU.
    static let tickInterval: Duration = .milliseconds(350)
    static let minAudioSeconds: Double = 0.3
    /// Silence this long after speech closes a segment.
    static let pauseSeconds: Double = 0.45
    /// No pause for this long: close the segment anyway, at the quietest
    /// moment of its last `forcedCutSearchSeconds`.
    static let maxSegmentSeconds: Double = 12
    static let forcedCutSearchSeconds: Double = 3
    static let frameSeconds: Double = 0.02
    /// Below this a frame counts as silence — the speech gate's threshold.
    static let silenceRMS: Double = 180

    struct Cut: Equatable {
        /// Byte offset into the open segment's audio.
        let offset: Int
        /// The closed stretch has speech in it (one without is skipped, not
        /// decoded — a model given silence makes words up).
        let voiced: Bool
    }

    /// Where to close the open segment (`pcm` = the audio since the last cut),
    /// or nil to keep it open: in the middle of the first pause after speech,
    /// or — no pause within `maxSegmentSeconds` — at its quietest recent frame.
    static func cut(_ pcm: Data, sampleRate: Double) -> Cut? {
        let frameBytes = Int(sampleRate * frameSeconds) * 2
        guard frameBytes > 0 else { return nil }
        let levels = frameLevels(pcm, frameBytes: frameBytes)
        let pauseFrames = max(1, Int((pauseSeconds / frameSeconds).rounded()))
        var voiced = false
        var runStart = -1
        for (i, level) in levels.enumerated() {
            if level >= silenceRMS { voiced = true; runStart = -1; continue }
            guard voiced else { continue }
            if runStart < 0 { runStart = i }
            if i - runStart + 1 >= pauseFrames {
                return Cut(offset: (runStart + pauseFrames / 2) * frameBytes, voiced: true)
            }
        }
        let maxFrames = Int(maxSegmentSeconds / frameSeconds)
        guard levels.count >= maxFrames else { return nil }
        let lo = max(1, maxFrames - Int(forcedCutSearchSeconds / frameSeconds))
        let quietest = (lo..<maxFrames).min { levels[$0] < levels[$1] } ?? maxFrames
        return Cut(offset: quietest * frameBytes,
                   voiced: levels[..<quietest].contains { $0 >= silenceRMS })
    }

    /// RMS of each whole frame of 16-bit little-endian mono PCM.
    static func frameLevels(_ pcm: Data, frameBytes: Int) -> [Double] {
        let samplesPerFrame = frameBytes / 2
        let frames = pcm.count / frameBytes
        guard frames > 0, samplesPerFrame > 0 else { return [] }
        var out = [Double](repeating: 0, count: frames)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            for f in 0..<frames {
                var acc = 0.0
                for i in 0..<samplesPerFrame {
                    let v = Double(base.loadUnaligned(fromByteOffset: (f * samplesPerFrame + i) * 2, as: Int16.self))
                    acc += v * v
                }
                out[f] = (acc / Double(samplesPerFrame)).squareRoot()
            }
        }
        return out
    }

    /// Where a VAD segment is decoded from in the clip. The VAD reports
    /// speech a little after it starts and closes a segment a little into
    /// what follows, so its own samples clip the first syllable and can end
    /// on the next one's onset. So: start `leadSeconds` earlier (never before
    /// what was already decoded), and end at the quietest moment of the
    /// segment's last `endSearchSeconds` — the real gap — rather than at its
    /// reported end.
    static let leadSeconds: Double = 0.3
    static let endSearchSeconds: Double = 0.3

    static func segmentBytes(in clip: Data, start: Int, count: Int, floor: Int,
                             sampleRate: Double) -> Range<Int> {
        let ceiling = clip.count & ~1
        let lead = Int(leadSeconds * sampleRate)
        let lo = min(ceiling, max(floor, (start - lead) * 2)) & ~1
        var hi = min(ceiling, (start + count) * 2) & ~1
        let frameBytes = Int(sampleRate * frameSeconds) * 2
        let searchLo = max(lo, hi - Int(endSearchSeconds * sampleRate) * 2) & ~1
        if frameBytes > 0, hi - searchLo >= frameBytes {
            let levels = frameLevels(clip.subdata(in: searchLo..<hi), frameBytes: frameBytes)
            if let quietest = levels.indices.min(by: { levels[$0] < levels[$1] }) {
                hi = (searchLo + quietest * frameBytes + frameBytes / 2) & ~1
            }
        }
        return lo..<max(lo, hi)
    }

    /// Put two decoded stretches together: CJK runs straight on, words of a
    /// Latin-script language get a space between them.
    static func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        guard let last = a.unicodeScalars.last, let first = b.unicodeScalars.first,
              last.isASCII, first.isASCII, !CharacterSet.whitespaces.contains(last),
              CharacterSet.alphanumerics.contains(first) else { return a + b }
        return a + " " + b
    }
}
