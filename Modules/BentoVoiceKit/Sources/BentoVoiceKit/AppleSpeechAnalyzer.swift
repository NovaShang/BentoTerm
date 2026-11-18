import Foundation
import Speech
import AVFoundation
import BentoFoundationKit

// Apple's newer speech model: `SpeechAnalyzer` + `SpeechTranscriber`
// (iOS/macOS 26). `AppleSpeechEngine` (SFSpeechRecognizer) stays as its own
// engine — it is the system-dictation model, and the two are compared side by
// side.
//
// Fallback chain, decided once per language and cached:
//   SpeechTranscriber (the new model) — if the device runs it and has a model
//     for the language;
//   DictationTranscriber — same API, the dictation model, for languages or
//     devices SpeechTranscriber doesn't cover;
//   SFSpeechRecognizer — below iOS 26, or when neither covers the language.
//
// Measured on macOS 27.2 (M-series Mac, 2026-11-10):
//   - zh_CN SpeechTranscriber asset ("com.apple.speech.asr.transcription.cmn")
//     is ~363 MB on disk; it was already installed as a system asset.
//   - `AssetInventory.status` said `.supported` for it in a fresh process even
//     though it was installed; `assetInstallationRequest` then returned nil
//     (nothing to download) and the status became `.installed`. So
//     "not installed" is only believed once the request comes back non-nil.
//   - `AnalysisContext.contextualStrings` changed nothing in SpeechTranscriber's
//     output (zh-CN or en-US). DictationTranscriber and SFSpeechRecognizer
//     DO honour contextual strings (en-US: "PNM" → "pnpm", "local list" →
//     "localhost"). The context is still set on both modules: it is free, and
//     the dictation fallback uses it.

public enum AppleSpeechAnalyzerSupport {
    /// The OS has `SpeechAnalyzer` at all.
    public static var osSupportsAnalyzer: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { return true }
        return false
    }
}

/// Which `SpeechAnalyzer` module a recording runs.
public enum AppleSpeechModule: String, Sendable, Equatable {
    /// `SpeechTranscriber` — the new model.
    case transcriber
    /// `DictationTranscriber` — the dictation model behind the same API.
    case dictation
}

/// What a recording on the "Apple (new model)" engine will actually run.
public enum AppleSpeechPlan: Equatable, Sendable {
    case analyzer(AppleSpeechModule, localeID: String)
    /// `SFSpeechRecognizer` — the old Apple engine's code path.
    case legacy

    /// The fallback chain, pure. `transcriberLocale` / `dictationLocale` are
    /// each module's supported locale equivalent to the chosen language (nil =
    /// that module has no model for it).
    public static func choose(osSupportsAnalyzer: Bool, transcriberAvailable: Bool,
                              transcriberLocale: String?, dictationLocale: String?) -> AppleSpeechPlan {
        guard osSupportsAnalyzer else { return .legacy }
        if transcriberAvailable, let id = transcriberLocale { return .analyzer(.transcriber, localeID: id) }
        if let id = dictationLocale { return .analyzer(.dictation, localeID: id) }
        return .legacy
    }
}

/// The `speech_locale` setting as a Locale ("auto" = the system's).
public func appleSpeechLocale(forSetting key: String) -> Locale {
    key == "auto" ? .current : Locale(identifier: key)
}

public enum AppleSpeechModelState: Equatable, Sendable {
    case unknown
    case checking
    case ready(AppleSpeechPlan)
    case needsDownload
    case downloading(fraction: Double)
    case failed(message: String)
}

/// The one line the voice gesture shows instead of recording while Apple's
/// model can't run yet; nil when the recording can go ahead.
public func appleSpeechModelUnavailableMessage(for state: AppleSpeechModelState) -> String? {
    switch state {
    case .unknown, .checking, .ready:
        return nil
    case .downloading(let fraction):
        return "Downloading Apple speech model… \(Int((fraction * 100).rounded(.down)))%"
    case .needsDownload:
        return "Apple speech model not downloaded — open Settings → Voice."
    case .failed(let message):
        return message
    }
}

/// Settings copy for the "Apple (new model)" engine. Here rather than in the
/// panel so it is tested with the rest.
public enum AppleSpeechModelCopy {
    public static func engineNote(osSupportsAnalyzer: Bool) -> String {
        osSupportsAnalyzer
            ? "Runs on this device."
            : "Needs iOS 26. Until then, voice uses Apple (on-device)."
    }

    /// The status line under the engine; nil = show the download button only.
    public static func status(for state: AppleSpeechModelState) -> String? {
        switch state {
        case .unknown, .checking:
            return "Checking Apple speech model…"
        case .ready(.analyzer(.transcriber, _)):
            return "Model ready"
        case .ready(.analyzer(.dictation, _)):
            return "Using Apple's dictation model — the new one doesn't cover this language."
        case .ready(.legacy):
            return "The new model doesn't cover this language. Voice uses Apple (on-device)."
        case .downloading(let fraction):
            return "Downloading Apple speech model… \(Int((fraction * 100).rounded(.down)))%"
        case .needsDownload:
            return nil
        case .failed(let message):
            return message
        }
    }

    public static let downloadButton = "Download model"
}

/// A resolved analyzer plan plus the audio format its module wants.
struct AppleReadyPlan: @unchecked Sendable {   // AVAudioFormat is immutable
    let module: AppleSpeechModule
    let localeID: String
    let format: AVAudioFormat

    @available(iOS 26.0, macOS 26.0, *)
    func makeModule() -> any SpeechModule {
        let locale = Locale(identifier: localeID)
        switch module {
        case .transcriber:
            // Volatile results are the live text. Not `.fastResults`: on the
            // same clip it cut the final short ("NPMonde" vs "NPMRundev。")
            // for ~150 ms less finalize time.
            return SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                     reportingOptions: [.volatileResults],
                                     attributeOptions: [])
        case .dictation:
            return DictationTranscriber(locale: locale, contentHints: [.shortForm],
                                        transcriptionOptions: [.punctuation],
                                        reportingOptions: [.volatileResults],
                                        attributeOptions: [])
        }
    }
}

// MARK: - Store (resolution, asset download)

/// Resolves the fallback chain and Apple's model download for the current
/// language, shared by the Settings row and the voice session so both see the
/// same download. Main-actor state; the Speech calls are async and the
/// download itself runs in the system's asset daemon.
@MainActor
public final class AppleSpeechModelStore: ObservableObject {
    public static let shared = AppleSpeechModelStore()

    /// State for `localeKey` (the last language checked).
    @Published public private(set) var state: AppleSpeechModelState = .unknown
    public private(set) var localeKey: String?

    private var readyPlans: [String: AppleReadyPlan] = [:]
    private var downloading: Task<Void, Never>?

    public init() {}

    /// The plan a hold can start on without awaiting anything; nil = resolve first.
    func cachedPlan(for key: String) -> AppleReadyPlan? { readyPlans[key] }
    /// The language resolved to the old engine.
    func isLegacy(for key: String) -> Bool { localeKey == key && state == .ready(.legacy) }

    /// Settings: what's the situation for this language (never downloads).
    public func refresh(localeKey key: String) {
        if localeKey == key, case .downloading = state { return }
        Task { _ = await prepare(localeKey: key, download: false) }
    }

    /// Settings button.
    public func download(localeKey key: String) {
        Task { _ = await prepare(localeKey: key, download: true) }
    }

    enum Outcome {
        case ready(AppleReadyPlan)
        case legacy
        /// Not runnable yet; the state's message says why.
        case unavailable
    }

    /// Walk the chain for `key`; with `download`, start fetching a missing
    /// model (the state then reports its progress).
    func prepare(localeKey key: String, download: Bool) async -> Outcome {
        if localeKey == key, case .downloading = state { return .unavailable }
        if let plan = readyPlans[key] {
            localeKey = key
            state = .ready(.analyzer(plan.module, localeID: plan.localeID))
            return .ready(plan)
        }
        guard #available(iOS 26.0, macOS 26.0, *) else {
            localeKey = key
            state = .ready(.legacy)
            return .legacy
        }
        localeKey = key
        state = .checking
        let outcome = await resolve(key: key, download: download)
        // Another language was asked about meanwhile: its state wins.
        guard localeKey == key else { return outcome }
        switch outcome {
        case .ready(let plan):
            readyPlans[key] = plan
            state = .ready(.analyzer(plan.module, localeID: plan.localeID))
        case .legacy:
            state = .ready(.legacy)
        case .unavailable:
            break   // resolve set the state
        }
        return outcome
    }

    /// Reserve `locale` for this app, releasing the oldest of our other
    /// reservations if the per-app limit is reached.
    @available(iOS 26.0, macOS 26.0, *)
    private static func reserve(_ locale: Locale) async {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return }
        if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            _ = await AssetInventory.release(reservedLocale: oldest)
        }
        do {
            let ok = try await AssetInventory.reserve(locale: locale)
            dlog("[voice] apple-new: reserve \(locale.identifier) → \(ok)")
        } catch {
            dlog("[voice] apple-new: reserve \(locale.identifier) FAILED: \(error.localizedDescription)")
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func resolve(key: String, download: Bool) async -> Outcome {
        let locale = appleSpeechLocale(forSetting: key)
        let transcriberAvailable = SpeechTranscriber.isAvailable
        var transcriberLocale = transcriberAvailable
            ? await SpeechTranscriber.supportedLocale(equivalentTo: locale)?.identifier : nil
        let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale)?.identifier

        for _ in 0..<2 {
            let plan = AppleSpeechPlan.choose(osSupportsAnalyzer: true,
                                              transcriberAvailable: transcriberAvailable,
                                              transcriberLocale: transcriberLocale,
                                              dictationLocale: dictationLocale)
            guard case .analyzer(let kind, let localeID) = plan else {
                dlog("[voice] apple-new: no analyzer model for \(locale.identifier) → SFSpeechRecognizer")
                return .legacy
            }
            // A language other than the ones the system already uses has to be
            // reserved by the app before its model is installed or usable. Left
            // out, the system language (English) works and zh-CN yields nothing.
            await Self.reserve(Locale(identifier: localeID))
            let probe = AppleReadyPlan(module: kind, localeID: localeID,
                                       format: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                             channels: 1, interleaved: true)!)
            let module = probe.makeModule()
            let status = await AssetInventory.status(forModules: [module])
            dlog("[voice] apple-new: \(kind) \(localeID) asset status=\(status)")
            if status == .unsupported {
                // This device can't run the transcriber for the language:
                // try the dictation model before giving up on the new API.
                if kind == .transcriber { transcriberLocale = nil; continue }
                return .legacy
            }
            if status != .installed {
                let request: AssetInstallationRequest?
                do {
                    request = try await AssetInventory.assetInstallationRequest(supporting: [module])
                } catch {
                    dlog("[voice] apple-new: asset request FAILED: \(error.localizedDescription)")
                    state = .failed(message: Self.downloadFailedMessage)
                    return .unavailable
                }
                if let request {
                    guard download else { state = .needsDownload; return .unavailable }
                    startDownload(request, key: key)
                    return .unavailable
                }
                // nil: nothing to fetch — the model is on the device.
            }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) ?? probe.format
            return .ready(AppleReadyPlan(module: kind, localeID: localeID, format: format))
        }
        return .legacy
    }

    nonisolated static let downloadFailedMessage = "Apple speech model didn't download — check your connection and try again."

    @available(iOS 26.0, macOS 26.0, *)
    private func startDownload(_ request: AssetInstallationRequest, key: String) {
        state = .downloading(fraction: request.progress.fractionCompleted)
        dlog("[voice] apple-new: downloading model for \(key)")
        downloading = Task { [weak self] in
            // Progress is KVO-observable, but a poll is all a one-line
            // percentage needs.
            let poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, self.localeKey == key, case .downloading = self.state else { continue }
                    self.state = .downloading(fraction: request.progress.fractionCompleted)
                }
            }
            defer { poll.cancel() }
            do {
                try await request.downloadAndInstall()
                guard let self else { return }
                self.downloading = nil
                dlog("[voice] apple-new: model installed for \(key)")
                if self.localeKey == key { self.state = .unknown }
                _ = await self.prepare(localeKey: key, download: false)
            } catch {
                guard let self else { return }
                self.downloading = nil
                dlog("[voice] apple-new: download FAILED: \(error.localizedDescription)")
                if self.localeKey == key { self.state = .failed(message: Self.downloadFailedMessage) }
            }
        }
    }
}

// MARK: - Recording

/// One hold on the analyzer engine. Not availability-gated so `VoiceSession`
/// can hold it on any OS.
protocol AppleAnalyzerRecording: AnyObject, Sendable {
    /// 16-bit mono PCM at the plan's sample rate, from the capture queue.
    func feed(_ pcm: Data)
    /// Start analysing once the vocabulary is in. PCM fed before this is
    /// buffered, so nothing said while it sets up is lost.
    func begin(vocabulary: Task<[String], Never>,
               onPartial: @escaping @Sendable (String) -> Void,
               onError: @escaping @Sendable (Error) -> Void)
    /// End of audio: wait (bounded) for the final text.
    func finish() async -> String
    func cancel()
}

@available(iOS 26.0, macOS 26.0, *)
final class SpeechAnalyzerRecording: AppleAnalyzerRecording, @unchecked Sendable {
    /// Bound on waiting for finalization after release, as the old engine.
    static let finishGrace: Duration = .milliseconds(1500)

    private let plan: AppleReadyPlan
    private let module: any SpeechModule
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    /// Int16 mono at the plan's rate: what `AudioCaptureService` delivers.
    private let captureFormat: AVAudioFormat
    /// Only touched from `feed` (the capture queue, serial).
    private var converter: AVAudioConverter?

    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    private var startTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    init(plan: AppleReadyPlan) {
        self.plan = plan
        self.module = plan.makeModule()
        // `.lingering` keeps the model loaded for a while after a hold, so
        // the next one doesn't pay the load again.
        self.analyzer = SpeechAnalyzer(modules: [module],
                                       options: .init(priority: .userInitiated, modelRetention: .lingering))
        (input, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        captureFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: plan.format.sampleRate,
                                      channels: 1, interleaved: true)!
    }

    var sampleRate: Double { plan.format.sampleRate }

    func feed(_ pcm: Data) {
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            if let src = raw.baseAddress { memcpy(dst, src, frames * MemoryLayout<Int16>.size) }
        }
        if plan.format == captureFormat {
            inputContinuation.yield(AnalyzerInput(buffer: buffer))
        } else if let converted = convert(buffer) {
            inputContinuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Only reached when the model wants something other than Int16 mono
    /// (it asked for exactly that on macOS 27).
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil { converter = AVAudioConverter(from: captureFormat, to: plan.format) }
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: plan.format, frameCapacity: buffer.frameLength + 64)
        else { return nil }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, status in
            if provided { status.pointee = .noDataNow; return nil }
            provided = true
            status.pointee = .haveData
            return buffer
        }
        return (error == nil && status != .error && out.frameLength > 0) ? out : nil
    }

    func begin(vocabulary: Task<[String], Never>,
               onPartial: @escaping @Sendable (String) -> Void,
               onError: @escaping @Sendable (Error) -> Void) {
        let module = self.module
        resultsTask = Task { [weak self] in
            do {
                if let transcriber = module as? SpeechTranscriber {
                    for try await r in transcriber.results {
                        self?.absorb(String(r.text.characters), isFinal: r.isFinal, onPartial: onPartial)
                    }
                } else if let dictation = module as? DictationTranscriber {
                    for try await r in dictation.results {
                        self?.absorb(String(r.text.characters), isFinal: r.isFinal, onPartial: onPartial)
                    }
                }
            } catch {
                dlog("[voice] apple-new results ended: \(error.localizedDescription)")
            }
        }
        startTask = Task { [weak self] in
            let strings = await vocabulary.value
            guard let self, !Task.isCancelled else { return }
            do {
                if !strings.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings = [.general: strings]
                    try await self.analyzer.setContext(context)
                }
                try await self.analyzer.start(inputSequence: self.input)
                dlog("[voice] apple-new started (\(self.plan.module) \(self.plan.localeID), \(strings.count) contextual strings)")
            } catch {
                dlog("[voice] apple-new start FAILED: \(error.localizedDescription)")
                onError(error)
            }
        }
    }

    /// Finalized text accumulates; the volatile tail is replaced by every
    /// newer volatile result and cleared once that range is finalized.
    private func absorb(_ text: String, isFinal: Bool, onPartial: @Sendable (String) -> Void) {
        lock.lock()
        if isFinal { finalized += text; volatile = "" } else { volatile = text }
        let combined = finalized + volatile
        lock.unlock()
        onPartial(combined.trimmingCharacters(in: .whitespaces))
    }

    private var currentText: String {
        lock.lock(); defer { lock.unlock() }
        return (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func finish() async -> String {
        inputContinuation.finish()
        let analyzer = self.analyzer
        let startTask = self.startTask, resultsTask = self.resultsTask
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await startTask?.value
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                await resultsTask?.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: Self.finishGrace)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !completed {
            dlog("[voice] apple-new: final didn't arrive in time — using what was shown")
            await analyzer.cancelAndFinishNow()
            resultsTask?.cancel()
        }
        return currentText
    }

    func cancel() {
        inputContinuation.finish()
        startTask?.cancel()
        resultsTask?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
