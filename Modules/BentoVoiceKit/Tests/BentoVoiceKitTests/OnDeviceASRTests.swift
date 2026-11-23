import XCTest
@testable import BentoVoiceKit

// MARK: - Engine selection

final class SenseVoiceSelectionTests: XCTestCase {
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "bento.sensevoice.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    /// No key, and — unlike the cloud engines — no silent Apple fallback when
    /// its model is missing: the gesture has to say so instead.
    func testSelectedSenseVoiceStaysSenseVoiceWithoutKeyOrModel() {
        let defaults = freshDefaults()
        defaults.set("sensevoice", forKey: "speech_engine")
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults), .senseVoice)
        XCTAssertNil(SpeechEngineKind.senseVoice.keyDefaultsKey)
        XCTAssertEqual(SpeechEngineKind.senseVoice.apiKey(defaults: defaults), "")
        XCTAssertEqual(SpeechEngineKind.senseVoice.onDeviceModel, .senseVoiceSmall)
        XCTAssertNil(SpeechEngineKind.apple.onDeviceModel)
        XCTAssertNil(SpeechEngineKind.qwen.onDeviceModel)
    }

    func testMissingModelGivesAClearLineNotSilence() {
        XCTAssertEqual(onDeviceModelUnavailableMessage(for: .notInstalled),
                       "Speech model not downloaded — open Settings → Voice.")
        XCTAssertEqual(onDeviceModelUnavailableMessage(for: .failed(message: "x")),
                       "Speech model not downloaded — open Settings → Voice.")
        XCTAssertEqual(onDeviceModelUnavailableMessage(for: .downloading(fraction: 0.429)),
                       "Downloading speech model… 42%")
        XCTAssertNotNil(onDeviceModelUnavailableMessage(for: .verifying))
        XCTAssertNil(onDeviceModelUnavailableMessage(for: .installed(bytes: 1)))
    }

    /// The session refuses to start (and reports the line) rather than
    /// recording audio it can't transcribe.
    @MainActor
    func testSessionReportsMissingModelInsteadOfRecording() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-missing-\(UUID().uuidString)", isDirectory: true)
        let store = OnDeviceModelStore(model: .senseVoiceSmall, directory: dir)
        XCTAssertEqual(store.state, .notInstalled)
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "speech_engine")
        defaults.set("sensevoice", forKey: "speech_engine")
        defer { defaults.set(saved, forKey: "speech_engine") }

        let session = VoiceSession(modelStore: store)
        var error: String?
        session.start(onPartial: { _ in }, onError: { error = $0 })
        XCTAssertEqual(error, "Speech model not downloaded — open Settings → Voice.")
        XCTAssertFalse(session.isActive)
    }
}

// MARK: - Manifest / layout / checksum

final class OnDeviceModelLayoutTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-layout-\(UUID().uuidString)", isDirectory: true)
        // Model files live in subdirectories (Core ML bundles), as here.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("model"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, _ content: Data) -> OnDeviceModelFile {
        OnDeviceModelFile(name: name, size: Int64(content.count),
                            sha256: sha(content), urls: [URL(string: "https://example.invalid/\(name)")!])
    }

    private func testModel(_ files: [OnDeviceModelFile]) -> OnDeviceASRModel {
        OnDeviceASRModel(id: "test-\(UUID().uuidString)", family: .senseVoice, files: files)
    }

    private func sha(_ d: Data) -> String {
        let url = dir.appendingPathComponent("hash-\(UUID().uuidString)")
        try! d.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try! sha256Hex(of: url)
    }

    func testSha256MatchesKnownVector() throws {
        let url = dir.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try sha256Hex(of: url),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testManifestIsWellFormed() {
        let files = OnDeviceASRModel.senseVoiceSmall.files
        let names = Set(files.map(\.name))
        XCTAssertEqual(names.count, files.count, "no file listed twice")
        // Everything the loaders open is in the download.
        typealias SV = OnDeviceASRModel.SenseVoiceFiles
        for bundle in [SV.preprocessor, SV.encoder, OnDeviceVAD.modelBundleName] {
            XCTAssertTrue(names.contains("\(bundle)/coremldata.bin"), bundle)
            XCTAssertTrue(names.contains("\(bundle)/model.mil"), bundle)
            XCTAssertTrue(names.contains("\(bundle)/weights/weight.bin"), bundle)
        }
        XCTAssertTrue(names.contains(SV.vocabulary))
        for f in files {
            XCTAssertEqual(f.sha256.count, 64)
            XCTAssertEqual(f.sha256, f.sha256.lowercased())
            XCTAssertGreaterThan(f.size, 0)
            XCTAssertFalse(f.urls.isEmpty)
            XCTAssertTrue(f.urls.allSatisfy { $0.scheme == "https" && $0.path.hasSuffix("/" + f.name) })
            // Pinned to a commit, never a moving branch: the hashes must stay true.
            XCTAssertTrue(f.urls.allSatisfy { !$0.path.contains("/resolve/main/") }, "\(f.urls)")
        }
        XCTAssertEqual(files.first?.name, SV.vocabulary, "small file first: fail fast")
        XCTAssertEqual(files.last?.name, "\(SV.encoder)/weights/weight.bin", "the big one last")
        XCTAssertGreaterThan(OnDeviceASRModel.senseVoiceSmall.totalBytes, 200_000_000)
    }

    func testVerifyChecksSizeAndHash() throws {
        let good = Data("hello model".utf8)
        let f = file("m.bin", good)
        let url = dir.appendingPathComponent("m.bin")
        try good.write(to: url)
        XCTAssertTrue(verify(fileAt: url, against: f))
        try Data("hello modeL".utf8).write(to: url)   // same size, different bytes
        XCTAssertFalse(verify(fileAt: url, against: f))
        try Data("short".utf8).write(to: url)
        XCTAssertFalse(verify(fileAt: url, against: f))
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(verify(fileAt: url, against: f))
    }

    func testInstalledNeedsFilesAndAMatchingMarker() throws {
        let a = Data("tokens".utf8), b = Data("weights!".utf8)
        let layout = OnDeviceModelLayout(directory: dir, files: [file("tokens.txt", a), file("model/weights.bin", b)])
        XCTAssertFalse(layout.isInstalled)
        XCTAssertEqual(layout.bytesOnDisk, 0)

        // Partial download counts toward the resume point but isn't installed.
        try Data("weig".utf8).write(to: layout.partURL(layout.files[1]))
        try a.write(to: layout.finalURL(layout.files[0]))
        XCTAssertEqual(layout.bytesOnDisk, Int64(a.count + 4))
        XCTAssertFalse(layout.isInstalled)

        try FileManager.default.removeItem(at: layout.partURL(layout.files[1]))
        try b.write(to: layout.finalURL(layout.files[1]))
        XCTAssertFalse(layout.isInstalled, "complete files without the verified marker don't count")

        try layout.markerContent.write(to: layout.markerURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(layout.isInstalled)

        // A different manifest (new model revision) invalidates the marker.
        let other = OnDeviceModelLayout(directory: dir, files: [file("tokens.txt", a), file("model/weights.bin", Data("weights?".utf8))])
        XCTAssertFalse(other.isInstalled)

        // A truncated file invalidates it too.
        try Data("w".utf8).write(to: layout.finalURL(layout.files[1]))
        XCTAssertFalse(layout.isInstalled)
    }

    @MainActor
    func testStoreReflectsDiskAndDeleteClearsIt() throws {
        let a = Data("tokens".utf8), b = Data("weights!".utf8)
        let files = [file("tokens.txt", a), file("model/weights.bin", b)]
        let layout = OnDeviceModelLayout(directory: dir, files: files)
        try a.write(to: layout.finalURL(files[0]))
        try b.write(to: layout.finalURL(files[1]))
        try layout.markerContent.write(to: layout.markerURL, atomically: true, encoding: .utf8)

        let store = OnDeviceModelStore(model: testModel(files), directory: dir)
        guard case .installed(let bytes) = store.state else { return XCTFail("\(store.state)") }
        XCTAssertGreaterThanOrEqual(bytes, Int64(a.count + b.count))

        store.delete()
        XCTAssertEqual(store.state, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    /// A served file whose bytes don't hash right is thrown away (clean retry),
    /// never marked installed.
    @MainActor
    func testCorruptDownloadIsDiscardedNotInstalled() async throws {
        let served = dir.appendingPathComponent("served", isDirectory: true)
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        let payload = Data("the real bytes".utf8)
        try Data("the fake bytes".utf8).write(to: served.appendingPathComponent("m.bin"))
        let f = OnDeviceModelFile(name: "m.bin", size: Int64(payload.count), sha256: sha(payload),
                                    urls: [served.appendingPathComponent("m.bin")])
        let target = dir.appendingPathComponent("model", isDirectory: true)
        let store = OnDeviceModelStore(model: testModel([f]), directory: target)
        store.download()
        for _ in 0..<200 {
            if case .failed = store.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed = store.state else { return XCTFail("expected failure, got \(store.state)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("m.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("m.bin.part").path))
        XCTAssertEqual(store.partialBytes, 0)
    }

    @MainActor
    func testGoodDownloadInstalls() async throws {
        let served = dir.appendingPathComponent("served", isDirectory: true)
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        let payload = Data(repeating: 7, count: 300_000)
        try payload.write(to: served.appendingPathComponent("m.bin"))
        let f = OnDeviceModelFile(name: "m.bin", size: Int64(payload.count), sha256: sha(payload),
                                    urls: [URL(string: "https://example.invalid/m.bin")!,   // dead mirror first
                                           served.appendingPathComponent("m.bin")])
        let target = dir.appendingPathComponent("model", isDirectory: true)
        let store = OnDeviceModelStore(model: testModel([f]), directory: target)
        store.download()
        for _ in 0..<500 {
            if store.state.isInstalled { break }
            if case .failed = store.state { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.state.isInstalled, "\(store.state)")
        XCTAssertTrue(OnDeviceModelLayout(directory: target, files: [f]).isInstalled)
    }
}

// MARK: - PCM conversion / resampling

final class ASRPCMTests: XCTestCase {
    func testInt16ToFloat() {
        var d = Data()
        for v: Int16 in [0, 16384, -16384, Int16.max, Int16.min] {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        let f = ASRPCM.floatSamples(int16LE: d)
        XCTAssertEqual(f.count, 5)
        XCTAssertEqual(f[0], 0)
        XCTAssertEqual(f[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(f[2], -0.5, accuracy: 1e-6)
        XCTAssertEqual(f[3], 32767.0 / 32768.0, accuracy: 1e-6)
        XCTAssertEqual(f[4], -1)
    }

    func testOddTrailingByteIsIgnored() {
        XCTAssertEqual(ASRPCM.floatSamples(int16LE: Data([0, 64, 9])).count, 1)
    }

    func testSameRateIsIdentity() {
        let x: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(ASRPCM.resample(x, from: 16000, to: 16000), x)
    }

    func testResampleLengthAndShape() {
        // 48k → 16k: a third as many samples.
        let x = (0..<4800).map { Float($0) / 4800 }
        let y = ASRPCM.resample(x, from: 48000, to: 16000)
        XCTAssertEqual(y.count, 1600)
        XCTAssertEqual(y[0], 0, accuracy: 1e-6)
        XCTAssertEqual(y[800], x[2400], accuracy: 1e-6)   // ramp stays a ramp

        // 24k → 16k and an up-sample.
        XCTAssertEqual(ASRPCM.resample([Float](repeating: 1, count: 2400), from: 24000, to: 16000).count, 1600)
        let up = ASRPCM.resample([0, 1], from: 8000, to: 16000)
        XCTAssertEqual(up.count, 4)
        XCTAssertEqual(up[1], 0.5, accuracy: 1e-6)
    }

    func testSinePreservesFrequencyAcrossResample() {
        // 440 Hz at 44.1k → 16k: zero crossings per second stay ~880.
        let n = 44100
        let x = (0..<n).map { Float(sin(2 * Double.pi * 440 * Double($0) / 44100)) }
        let y = ASRPCM.resample(x, from: 44100, to: 16000)
        XCTAssertEqual(y.count, 16000)
        var crossings = 0
        for i in 1..<y.count where (y[i - 1] < 0) != (y[i] < 0) { crossings += 1 }
        XCTAssertEqual(Double(crossings), 880, accuracy: 4)
    }

    func testReadsFixtureWav() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zh-sample", withExtension: "wav", subdirectory: "Fixtures"))
        let wav = try XCTUnwrap(ASRPCM.readWAV(try Data(contentsOf: url)))
        XCTAssertEqual(wav.sampleRate, 16000)
        XCTAssertEqual(Double(wav.samples.count) / wav.sampleRate, 3.7, accuracy: 0.2)
        XCTAssertNil(ASRPCM.readWAV(Data("not a wav".utf8)))
    }
}

// MARK: - Simulated streaming policy

final class OnDevicePartialPolicyTests: XCTestCase {
    private let rate = 16_000.0
    private func bytes(_ seconds: Double) -> Int { Int(seconds * rate) * 2 }

    /// `seconds` of a steady tone at `amplitude` (0 = silence).
    private func audio(_ parts: [(seconds: Double, amplitude: Int16)]) -> Data {
        var d = Data()
        for part in parts {
            let n = Int(part.seconds * rate)
            for i in 0..<n {
                var v = i % 2 == 0 ? part.amplitude : -part.amplitude
                withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
            }
        }
        return d
    }

    func testKeepsTheSegmentOpenWhileTalking() {
        XCTAssertNil(OnDevicePartialPolicy.cut(audio([(3, 2000)]), sampleRate: rate))
    }

    func testAShortBreathIsNotAPause() {
        XCTAssertNil(OnDevicePartialPolicy.cut(audio([(1, 2000), (0.2, 0), (1, 2000)]), sampleRate: rate))
    }

    func testClosesInTheMiddleOfAPause() {
        let cut = OnDevicePartialPolicy.cut(audio([(1, 2000), (0.6, 0), (1, 2000)]), sampleRate: rate)
        XCTAssertEqual(cut?.voiced, true)
        let offset = try? XCTUnwrap(cut).offset
        XCTAssertGreaterThan(offset ?? 0, bytes(1))
        XCTAssertLessThan(offset ?? 0, bytes(1.45))
        XCTAssertEqual((offset ?? 1) % 2, 0, "whole samples only")
    }

    func testSilenceBeforeSpeechIsNotAPause() {
        XCTAssertNil(OnDevicePartialPolicy.cut(audio([(1, 0), (2, 2000)]), sampleRate: rate))
    }

    func testForcesACutWhenThereIsNoPause() {
        let long = audio([(10, 2000), (0.1, 50), (4, 2000)])
        let cut = OnDevicePartialPolicy.cut(long, sampleRate: rate)
        XCTAssertEqual(cut?.voiced, true)
        // The quiet dip at 10 s, not an arbitrary point.
        XCTAssertEqual(Double(cut?.offset ?? 0) / Double(bytes(1)), 10, accuracy: 0.1)
    }

    func testJoinsCJKStraightAndLatinWithASpace() {
        XCTAssertEqual(OnDevicePartialPolicy.join("今天天气很好。", "我们去公园。"), "今天天气很好。我们去公园。")
        XCTAssertEqual(OnDevicePartialPolicy.join("run the build.", "Then commit"), "run the build. Then commit")
        XCTAssertEqual(OnDevicePartialPolicy.join("", "x"), "x")
        XCTAssertEqual(OnDevicePartialPolicy.join("x", ""), "x")
    }

    func testTickIsAFewHundredMilliseconds() {
        XCTAssertGreaterThanOrEqual(OnDevicePartialPolicy.tickInterval, .milliseconds(250))
        XCTAssertLessThanOrEqual(OnDevicePartialPolicy.tickInterval, .milliseconds(500))
    }
}

// MARK: - Real model (only when it's on this machine)

/// Runs the actual model through the Swift wrapper. Skipped unless the model
/// has been downloaded (by the app's Settings → Voice, into
/// ~/Library/Application Support/Bento/SpeechModels, or wherever
/// BENTO_SPEECH_MODELS_DIR points). `SENSEVOICE_WAV=/path/x.wav` transcribes
/// another 16-bit WAV instead of the fixture and prints the result.
final class SenseVoiceRealModelTests: XCTestCase {
    /// Opt-in (`BENTO_DOWNLOAD_REAL_MODEL=1`, ~240 MB): the real download from
    /// the real mirrors into the real location — cancelled part-way, then
    /// resumed, then verified. Leaves the model installed for the test below.
    @MainActor
    func testRealDownloadCancelResumeVerify() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BENTO_DOWNLOAD_REAL_MODEL"] == "1",
                          "set BENTO_DOWNLOAD_REAL_MODEL=1 to download the real model")
        let store = OnDeviceModelStore(model: .senseVoiceSmall)
        if store.state.isInstalled { store.delete() }
        store.download()
        while true {
            if case .downloading(let f) = store.state, f > 0.15 { break }
            if case .failed(let m) = store.state { return XCTFail(m) }
            try await Task.sleep(for: .milliseconds(50))
        }
        store.cancelDownload()
        while case .downloading = store.state { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.state, .notInstalled)
        let kept = store.partialBytes
        XCTAssertGreaterThan(kept, 0, "cancel keeps the partial download")
        print("[sensevoice-check] cancelled at \(kept) bytes; resuming")

        let t0 = Date()
        store.download()
        guard case .downloading(let resumedAt) = store.state else { return XCTFail("\(store.state)") }
        XCTAssertGreaterThan(resumedAt, 0.1, "resumes from the partial, not from zero")
        while !store.state.isInstalled {
            if case .failed(let m) = store.state { return XCTFail(m) }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("[sensevoice-check] resumed + verified in \(Int(Date().timeIntervalSince(t0)))s → \(store.state)")
    }

    /// Long dictation through the same segmenting the app's ticks use: the
    /// text before the open segment must never change between partials.
    func testLongHoldOnlyEverExtendsItsText() async throws {
        let model = OnDeviceASRModel.senseVoiceSmall
        let dir = model.defaultDirectory
        try XCTSkipUnless(OnDeviceModelLayout(directory: dir, files: model.files).isInstalled,
                          "SenseVoice model not downloaded at \(dir.path)")
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zh-sample", withExtension: "wav", subdirectory: "Fixtures"))
        let wav = try XCTUnwrap(ASRPCM.readWAV(try Data(contentsOf: url)))
        let rate = wav.sampleRate
        var one = Data()
        for x in wav.samples {
            var v = Int16(max(-1, min(1, x)) * 32767)
            withUnsafeBytes(of: &v) { one.append(contentsOf: $0) }
        }
        let pause = Data(count: Int(rate * 0.7) * 2)
        // Three sentences with pauses, then three run together, then one more.
        var clip = Data()
        for part in [one, pause, one, pause, one, pause, one, one, one, pause, one] { clip.append(part) }
        let engine = OnDeviceASREngine()
        let step = Int(rate * 0.35) * 2
        var committedBytes = 0, committed = ""
        var shownHistory: [String] = []
        var end = 0
        while end < clip.count {
            end = min(clip.count, end + step)
            let open = clip.subdata(in: committedBytes..<end)
            if let cut = OnDevicePartialPolicy.cut(open, sampleRate: rate) {
                if cut.voiced {
                    let text = try await engine.transcribe(pcm16: open.subdata(in: 0..<cut.offset), sampleRate: rate,
                                                           model: model, directory: dir)
                    committed = OnDevicePartialPolicy.join(committed, text)
                }
                committedBytes += cut.offset
            }
            let tail = clip.subdata(in: committedBytes..<end)
            let tailText = tail.count >= Int(rate * 0.3) * 2
                ? try await engine.transcribe(pcm16: tail, sampleRate: rate, model: model, directory: dir) : ""
            let shown = OnDevicePartialPolicy.join(committed, tailText)
            XCTAssertTrue(shown.hasPrefix(committed))
            if shownHistory.last != shown { shownHistory.append(shown) }
        }
        let seconds = Double(clip.count) / 2 / rate
        print("[sensevoice-long] \(String(format: "%.1f", seconds))s clip, \(shownHistory.count) distinct partials")
        for line in shownHistory.suffix(6) { print("[sensevoice-long]   \(line)") }
        print("[sensevoice-long] committed: \(committed)")
    }

    /// Quick speech with only short breaths between phrases — what a loudness
    /// cut can't split. The VAD must close segments there, so no stretch is
    /// re-decoded for long and the text only ever grows.
    func testFastSpeechIsCutIntoShortSegmentsByTheVAD() async throws {
        let model = OnDeviceASRModel.senseVoiceSmall
        let dir = model.defaultDirectory
        try XCTSkipUnless(OnDeviceModelLayout(directory: dir, files: model.files).isInstalled,
                          "SenseVoice model not downloaded at \(dir.path)")
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zh-sample", withExtension: "wav", subdirectory: "Fixtures"))
        let wav = try XCTUnwrap(ASRPCM.readWAV(try Data(contentsOf: url)))
        let rate = wav.sampleRate
        var one = Data()
        for x in wav.samples {
            var v = Int16(max(-1, min(1, x)) * 32767)
            withUnsafeBytes(of: &v) { one.append(contentsOf: $0) }
        }
        // The fixture's own leading/trailing quiet trimmed to ~0.15 s gaps.
        let gap = Data(count: Int(rate * 0.15) * 2)
        var clip = Data()
        for _ in 0..<8 { clip.append(one); clip.append(gap) }

        let segmenter = try OnDeviceSegmenter(directory: dir)
        let engine = OnDeviceASREngine()
        let step = Int(rate * 0.35) * 2
        var committedBytes = 0, committed = ""
        var fed = 0, maxOpenSeconds = 0.0, segments = 0
        var history: [String] = []
        while fed < clip.count {
            let end = min(clip.count, fed + step)
            let (closed, speaking) = await segmenter.accept(pcm16: clip.subdata(in: fed..<end))
            fed = end
            for seg in closed where seg.count > 0 {
                segments += 1
                let range = OnDevicePartialPolicy.segmentBytes(in: clip.subdata(in: 0..<fed), start: seg.start,
                                                               count: seg.count, floor: committedBytes, sampleRate: rate)
                let text = try await engine.transcribe(pcm16: clip.subdata(in: range), sampleRate: rate,
                                                       model: model, directory: dir)
                committed = OnDevicePartialPolicy.join(committed, text)
                committedBytes = max(committedBytes, range.upperBound)
            }
            var open = ""
            if speaking, fed > committedBytes {
                maxOpenSeconds = max(maxOpenSeconds, Double(fed - committedBytes) / 2 / rate)
                open = try await engine.transcribe(pcm16: clip.subdata(in: committedBytes..<fed), sampleRate: rate,
                                                   model: model, directory: dir)
            }
            let shown = OnDevicePartialPolicy.join(committed, open)
            XCTAssertTrue(shown.hasPrefix(committed))
            if history.last != shown { history.append(shown) }
        }
        for seg in await segmenter.finish(pcm16: Data()) where seg.count > 0 {
            segments += 1
            let range = OnDevicePartialPolicy.segmentBytes(in: clip, start: seg.start, count: seg.count,
                                                           floor: committedBytes, sampleRate: rate)
            committed = OnDevicePartialPolicy.join(committed, try await engine.transcribe(
                pcm16: clip.subdata(in: range), sampleRate: rate, model: model, directory: dir))
            committedBytes = range.upperBound
        }
        print("[sensevoice-fast] \(String(format: "%.1f", Double(clip.count) / 2 / rate))s, \(segments) segments, longest open stretch \(String(format: "%.1f", maxOpenSeconds))s, \(history.count) partials")
        print("[sensevoice-fast] final: \(committed)")
        XCTAssertLessThanOrEqual(maxOpenSeconds, Double(OnDeviceVAD.maxSpeech) + 1)
        XCTAssertGreaterThanOrEqual(segments, 4)
    }

    func testTranscribesFixtureWithRealModel() async throws {
        let model = OnDeviceASRModel.senseVoiceSmall
        let dir = model.defaultDirectory
        let layout = OnDeviceModelLayout(directory: dir, files: OnDeviceASRModel.senseVoiceSmall.files)
        let present = layout.isInstalled
            || OnDeviceASRModel.senseVoiceSmall.files.allSatisfy { layout.fileSize(layout.finalURL($0)) == $0.size }
        try XCTSkipUnless(present, "SenseVoice model not downloaded at \(dir.path)")

        let custom = ProcessInfo.processInfo.environment["SENSEVOICE_WAV"]
        let url = try custom.map { URL(fileURLWithPath: $0) }
            ?? XCTUnwrap(Bundle.module.url(forResource: "zh-sample", withExtension: "wav", subdirectory: "Fixtures"))
        let wav = try XCTUnwrap(ASRPCM.readWAV(try Data(contentsOf: url)))

        let engine = OnDeviceASREngine()
        let t0 = Date()
        let first = try await engine.transcribe(samples: wav.samples, sampleRate: wav.sampleRate, model: model, directory: dir)
        let cold = Date().timeIntervalSince(t0)
        let t1 = Date()
        let second = try await engine.transcribe(samples: wav.samples, sampleRate: wav.sampleRate, model: model, directory: dir)
        let warm = Date().timeIntervalSince(t1)
        let audio = Double(wav.samples.count) / wav.sampleRate
        print("[sensevoice-check] \(url.lastPathComponent) (\(String(format: "%.2f", audio))s @\(Int(wav.sampleRate))Hz) → \"\(first)\"")
        print("[sensevoice-check] cold (load+decode) \(Int(cold * 1000))ms, warm decode \(Int(warm * 1000))ms")
        XCTAssertEqual(first, second)
        if custom == nil {
            // "今天天气很好，我们去公园散步吧。" — ITN on, so punctuation comes back.
            XCTAssertTrue(first.contains("今天天气很好"), first)
            XCTAssertTrue(first.contains("公园散步"), first)
            XCTAssertTrue(first.contains("，") || first.contains("。"), "use_itn should punctuate: \(first)")
        }
    }

    /// Latency of the decodes simulated streaming runs: a 3 s and a 10 s clip
    /// (warm), and the partials a 350 ms tick would produce over the fixture.
    func testDecodeLatencyForLivePartials() async throws {
        let model = OnDeviceASRModel.senseVoiceSmall
        let dir = model.defaultDirectory
        try XCTSkipUnless(OnDeviceModelLayout(directory: dir, files: model.files).isInstalled,
                          "SenseVoice model not downloaded at \(dir.path)")
        let url = try XCTUnwrap(Bundle.module.url(forResource: "zh-sample", withExtension: "wav", subdirectory: "Fixtures"))
        let wav = try XCTUnwrap(ASRPCM.readWAV(try Data(contentsOf: url)))
        let engine = OnDeviceASREngine()
        _ = try await engine.transcribe(samples: wav.samples, sampleRate: 16000, model: model, directory: dir) // warm

        func median(_ samples: [Float], runs: Int = 5) async throws -> Int {
            var ms: [Int] = []
            for _ in 0..<runs {
                let t0 = Date()
                _ = try await engine.transcribe(samples: samples, sampleRate: 16000, model: model, directory: dir)
                ms.append(Int(Date().timeIntervalSince(t0) * 1000))
            }
            return ms.sorted()[runs / 2]
        }
        let three = Array(wav.samples.prefix(48_000))
        var ten: [Float] = []
        while ten.count < 160_000 { ten += wav.samples + [Float](repeating: 0, count: 4_000) }
        ten = Array(ten.prefix(160_000))
        let ms3 = try await median(three)
        let ms10 = try await median(ten)
        print("[sensevoice-check] warm decode median: 3 s clip \(ms3) ms, 10 s clip \(ms10) ms (tick \(OnDevicePartialPolicy.tickInterval))")

        // The partials a live hold would show, one per tick of captured audio.
        let tickSamples = Int(Double(16000) * 0.35)
        var n = Int(OnDevicePartialPolicy.minAudioSeconds * 16000)
        while n < wav.samples.count {
            let t0 = Date()
            let text = try await engine.transcribe(samples: Array(wav.samples.prefix(n)), sampleRate: 16000,
                                                   model: model, directory: dir)
            print("[sensevoice-check] partial @\(String(format: "%.2f", Double(n) / 16000))s (\(Int(Date().timeIntervalSince(t0) * 1000)) ms): \(text)")
            n += tickSamples
        }
        XCTAssertLessThan(ms3, 350, "a 3 s partial must fit inside one tick")
    }

    /// Opt-in (`BENTO_ANE_COMPILE_CHECK=1`, a few minutes): a copy of the model
    /// at a path Core ML has never compiled for the Neural Engine. The first
    /// sentence must come back in seconds (CPU), not after the compile; the
    /// compile then finishes in the background, leaves its marker, and the
    /// engine moves onto the Neural Engine.
    func testFreshModelDecodesOnTheCPUWhileTheNeuralEngineCompiles() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BENTO_ANE_COMPILE_CHECK"] == "1",
                          "set BENTO_ANE_COMPILE_CHECK=1 to time a first-ever Neural Engine compile")
        let model = OnDeviceASRModel.senseVoiceSmall
        try XCTSkipUnless(OnDeviceModelLayout(directory: model.defaultDirectory, files: model.files).isInstalled,
                          "SenseVoice model not downloaded at \(model.defaultDirectory.path)")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-fresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: model.defaultDirectory, to: dir)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(OnDeviceASREngine.neuralEngineMarker))
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try XCTUnwrap(Bundle.module.url(forResource: "zh-sample", withExtension: "wav", subdirectory: "Fixtures"))
        let wav = try XCTUnwrap(ASRPCM.readWAV(try Data(contentsOf: url)))
        let engine = OnDeviceASREngine()
        let t0 = Date()
        let first = try await engine.transcribe(samples: wav.samples, sampleRate: wav.sampleRate, model: model, directory: dir)
        let firstSeconds = Date().timeIntervalSince(t0)
        print("[sensevoice-ane] first sentence on a fresh copy in \(Int(firstSeconds * 1000)) ms → \(first)")
        XCTAssertTrue(first.contains("公园散步"), first)
        XCTAssertLessThan(firstSeconds, 15)

        let marker = dir.appendingPathComponent(OnDeviceASREngine.neuralEngineMarker)
        while !FileManager.default.fileExists(atPath: marker.path) {
            XCTAssertLessThan(Date().timeIntervalSince(t0), 600, "Neural Engine compile never finished")
            if Date().timeIntervalSince(t0) > 600 { return }
            try await Task.sleep(for: .seconds(2))
        }
        print("[sensevoice-ane] Neural Engine ready \(Int(Date().timeIntervalSince(t0)))s after the first load")
        try await Task.sleep(for: .milliseconds(200))   // the swap lands on the engine queue
        var ms: [Int] = []
        for _ in 0..<5 {
            let t = Date()
            _ = try await engine.transcribe(samples: wav.samples, sampleRate: wav.sampleRate, model: model, directory: dir)
            ms.append(Int(Date().timeIntervalSince(t) * 1000))
        }
        print("[sensevoice-ane] warm decode after the swap: median \(ms.sorted()[2]) ms")
    }
}
