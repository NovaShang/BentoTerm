import XCTest
@testable import BentoVoiceKit

/// The "Apple (new model)" fallback chain and its user-facing lines. The live
/// recognizer needs a mic and Apple's assets; the CLI comparison in the
/// commit message covers that.
final class AppleSpeechAnalyzerTests: XCTestCase {

    // MARK: Fallback chain

    func testTranscriberWhenTheDeviceRunsItAndHasTheLanguage() {
        XCTAssertEqual(
            AppleSpeechPlan.choose(osSupportsAnalyzer: true, transcriberAvailable: true,
                                   transcriberLocale: "zh_CN", dictationLocale: "zh_CN"),
            .analyzer(.transcriber, localeID: "zh_CN"))
    }

    func testDictationWhenTheTranscriberHasNoModelForTheLanguage() {
        XCTAssertEqual(
            AppleSpeechPlan.choose(osSupportsAnalyzer: true, transcriberAvailable: true,
                                   transcriberLocale: nil, dictationLocale: "th_TH"),
            .analyzer(.dictation, localeID: "th_TH"))
    }

    func testDictationWhenTheDeviceCantRunTheTranscriber() {
        XCTAssertEqual(
            AppleSpeechPlan.choose(osSupportsAnalyzer: true, transcriberAvailable: false,
                                   transcriberLocale: "en_US", dictationLocale: "en_US"),
            .analyzer(.dictation, localeID: "en_US"))
    }

    func testOldEngineWhenNeitherModuleHasTheLanguage() {
        XCTAssertEqual(
            AppleSpeechPlan.choose(osSupportsAnalyzer: true, transcriberAvailable: true,
                                   transcriberLocale: nil, dictationLocale: nil),
            .legacy)
    }

    func testOldEngineBelowIOS26WhateverTheLocales() {
        XCTAssertEqual(
            AppleSpeechPlan.choose(osSupportsAnalyzer: false, transcriberAvailable: true,
                                   transcriberLocale: "zh_CN", dictationLocale: "zh_CN"),
            .legacy)
    }

    func testAutoLanguageIsTheSystemLocale() {
        XCTAssertEqual(appleSpeechLocale(forSetting: "auto"), .current)
        XCTAssertEqual(appleSpeechLocale(forSetting: "zh-Hans").identifier, "zh-Hans")
    }

    // MARK: Gesture line

    func testGestureLineWhileDownloadingShowsProgress() {
        XCTAssertEqual(appleSpeechModelUnavailableMessage(for: .downloading(fraction: 0.429)),
                       "Downloading Apple speech model… 42%")
        XCTAssertEqual(appleSpeechModelUnavailableMessage(for: .downloading(fraction: 0)),
                       "Downloading Apple speech model… 0%")
    }

    func testGestureLineIsSilentWhenTheHoldCanGoAhead() {
        XCTAssertNil(appleSpeechModelUnavailableMessage(for: .ready(.analyzer(.transcriber, localeID: "zh_CN"))))
        XCTAssertNil(appleSpeechModelUnavailableMessage(for: .ready(.legacy)))
        XCTAssertNil(appleSpeechModelUnavailableMessage(for: .checking))
        XCTAssertNil(appleSpeechModelUnavailableMessage(for: .unknown))
    }

    func testGestureLineSaysWhatToDo() {
        XCTAssertEqual(appleSpeechModelUnavailableMessage(for: .needsDownload),
                       "Apple speech model not downloaded — open Settings → Voice.")
        XCTAssertEqual(appleSpeechModelUnavailableMessage(for: .failed(message: AppleSpeechModelStore.downloadFailedMessage)),
                       "Apple speech model didn't download — check your connection and try again.")
    }

    // MARK: Settings copy

    func testSettingsStatusLines() {
        XCTAssertEqual(AppleSpeechModelCopy.status(for: .ready(.analyzer(.transcriber, localeID: "zh_CN"))),
                       "Model ready")
        XCTAssertEqual(AppleSpeechModelCopy.status(for: .ready(.analyzer(.dictation, localeID: "th_TH"))),
                       "Using Apple's dictation model — the new one doesn't cover this language.")
        XCTAssertEqual(AppleSpeechModelCopy.status(for: .ready(.legacy)),
                       "The new model doesn't cover this language. Voice uses Apple (on-device).")
        XCTAssertEqual(AppleSpeechModelCopy.status(for: .downloading(fraction: 0.5)),
                       "Downloading Apple speech model… 50%")
        XCTAssertNil(AppleSpeechModelCopy.status(for: .needsDownload), "the button is the whole row")
    }

    func testEngineNote() {
        XCTAssertEqual(AppleSpeechModelCopy.engineNote(osSupportsAnalyzer: true), "Runs on this device.")
        XCTAssertEqual(AppleSpeechModelCopy.engineNote(osSupportsAnalyzer: false),
                       "Needs iOS 26. Until then, voice uses Apple (on-device).")
    }
}

// MARK: - Real recognizer (opt-in)

/// Streams a 16 kHz 16-bit WAV through the same recording class a hold uses
/// (feed → volatile partials → finish), against Apple's real model. Opt-in:
/// `APPLE_SPEECH_WAV=/path/x.wav` (`APPLE_SPEECH_LOCALE`, default zh-Hans).
/// Never downloads — skipped when the model isn't on this machine.
final class AppleSpeechAnalyzerRealModelTests: XCTestCase {
    @MainActor
    func testStreamsAWavThroughTheRecording() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPLE_SPEECH_WAV"] else {
            throw XCTSkip("set APPLE_SPEECH_WAV to a 16 kHz 16-bit WAV")
        }
        guard #available(iOS 26.0, macOS 26.0, *) else { throw XCTSkip("needs SpeechAnalyzer") }
        let key = ProcessInfo.processInfo.environment["APPLE_SPEECH_LOCALE"] ?? "zh-Hans"
        let store = AppleSpeechModelStore()
        guard case .ready(let plan) = await store.prepare(localeKey: key, download: false) else {
            throw XCTSkip("no runnable analyzer model for \(key): \(store.state)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let wav = try XCTUnwrap(ASRPCM.readWAV(data))
        XCTAssertEqual(wav.sampleRate, plan.format.sampleRate)
        let pcm = Data(wav.samples.flatMap { f -> [UInt8] in
            let v = Int16(max(-32768, min(32767, (f * 32768).rounded())))
            return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
        })
        for vocabulary in [[], ["tmux", "npm run dev", "Claude Code", "pnpm", "localhost"]] {
            let rec = SpeechAnalyzerRecording(plan: plan)
            let partials = PartialLog()
            rec.begin(vocabulary: Task { vocabulary }, onPartial: { partials.add($0) },
                      onError: { XCTFail("\($0)") })
            let chunk = 3200   // 100 ms
            var offset = 0
            while offset < pcm.count {
                rec.feed(pcm.subdata(in: offset..<min(offset + chunk, pcm.count)))
                offset += chunk
                try await Task.sleep(for: .milliseconds(25))
            }
            let t0 = Date()
            let final = await rec.finish()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[apple-new-check] \(plan.module) \(plan.localeID) vocab=\(vocabulary.count) partials=\(partials.count) finish=\(ms)ms → \"\(final)\"")
            XCTAssertFalse(final.isEmpty)
            XCTAssertGreaterThan(partials.count, 1, "volatile results stream while audio arrives")
        }
    }
}

private final class PartialLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}
