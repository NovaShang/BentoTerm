import Foundation
import CryptoKit
import BentoFoundationKit

// MARK: - Catalogue

/// One file of a downloadable model: where to get it and what it must hash to.
/// `name` may contain a subdirectory ("tokenizer/vocab.json").
public struct OnDeviceModelFile: Sendable, Equatable {
    public let name: String
    public let size: Int64
    /// Lowercase hex SHA-256.
    public let sha256: String
    /// Tried in order; a mirror is safe because the hash is checked anyway.
    public let urls: [URL]

    public init(name: String, size: Int64, sha256: String, urls: [URL]) {
        self.name = name; self.size = size; self.sha256 = sha256; self.urls = urls
    }
}

/// An offline (non-streaming) speech model the app can download and run as
/// Core ML through FluidAudio. Adding another one is a catalogue entry: its
/// files, and which family loads them (`Family` → the loader, in
/// OnDeviceASREngine).
public struct OnDeviceASRModel: Sendable, Equatable, Identifiable {
    public enum Family: String, Sendable { case senseVoice }

    public let id: String
    public let family: Family
    public let files: [OnDeviceModelFile]

    public init(id: String, family: Family, files: [OnDeviceModelFile]) {
        self.id = id; self.family = family; self.files = files
    }

    public static let sampleRate = 16_000

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public var defaultDirectory: URL { Self.modelsRoot.appendingPathComponent(id, isDirectory: true) }

    /// `<Application Support>/Bento/SpeechModels` — in the app container on
    /// iOS, `~/Library/Application Support` on the (unsandboxed) Mac.
    /// `BENTO_SPEECH_MODELS_DIR` overrides it (tests, scripts).
    public static var modelsRoot: URL {
        if let override = ProcessInfo.processInfo.environment["BENTO_SPEECH_MODELS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSup.appendingPathComponent("Bento/SpeechModels", isDirectory: true)
    }

    /// Hugging Face first, then its public mirror for networks where
    /// huggingface.co is unreachable. Pinned to a commit, so the hashes in
    /// the catalogue stay true when the repo moves on.
    static func hf(_ repo: String, _ revision: String, _ file: String) -> [URL] {
        [URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)")!,
         URL(string: "https://hf-mirror.com/\(repo)/resolve/\(revision)/\(file)")!]
    }

    /// Model directories older builds downloaded that nothing reads any more
    /// (SenseVoice as a sherpa-onnx export, ~240 MB). The store removes them.
    static let retiredDirectoryNames = ["sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17-int8"]

    /// SenseVoice's files inside its directory. Spelled out here, with the
    /// manifest, rather than taken from FluidAudio's `ModelNames`, so a
    /// FluidAudio bump can't point the loader at a file we never downloaded.
    enum SenseVoiceFiles {
        static let preprocessor = "SenseVoicePreprocessor.mlmodelc"
        static let encoder = "SenseVoiceSmall_int8.mlmodelc"
        static let vocabulary = "vocab.json"
    }

    /// SenseVoiceSmall (FunAudioLLM, 2024-07-17; zh/en/ja/ko/yue) as
    /// FluidInference's Core ML export: a CPU preprocessor plus the int8
    /// encoder, which runs on the Neural Engine and is the same size as the
    /// int8 ONNX it replaced. Silero VAD (MIT) rides along in the same
    /// download — it cuts a hold into segments for the live text.
    ///
    /// The files come from this fixed list through our own downloader, not
    /// FluidAudio's: FluidAudio lists the repo through the huggingface.co API,
    /// which hf-mirror.com redirects straight back to huggingface.co, so it
    /// has no fallback where huggingface.co is blocked. A fixed list also gives
    /// byte-exact progress, resume and a hash check. The layout is what
    /// `SenseVoiceModels.load(from:precision:)` reads.
    ///
    /// Weights: FunASR Model Open Source License 1.1 (attribution kept).
    /// vocab.json first: it is small, so a dead network fails fast instead of
    /// after the user has watched the big file crawl.
    public static let senseVoiceSmall: OnDeviceASRModel = {
        let sv = "FluidInference/sensevoice-small-coreml"
        let svRev = "74bdbe74b2258f25b5400db72f6cbfbef7c74ded"
        let vad = "FluidInference/silero-vad-coreml"
        let vadRev = "b419383c55c110e2c9271fa6ee0ea83d03c70d96"
        func f(_ repo: String, _ rev: String, _ name: String, _ size: Int64, _ sha: String) -> OnDeviceModelFile {
            OnDeviceModelFile(name: name, size: size, sha256: sha, urls: hf(repo, rev, name))
        }
        let pre = SenseVoiceFiles.preprocessor
        let enc = SenseVoiceFiles.encoder
        let v = OnDeviceVAD.modelBundleName
        return OnDeviceASRModel(
            id: "sensevoice-small-coreml-int8",
            family: .senseVoice,
            files: [
                f(sv, svRev, SenseVoiceFiles.vocabulary, 352_064,
                  "a2594fc1474e78973149cba8cd1f603ebed8c39c7decb470631f66e70ce58e97"),
                f(sv, svRev, "\(pre)/coremldata.bin", 330,
                  "e64cc73b2a9b01bad799a23874bc20dba3cf3342c23e3f60012c3e884f682944"),
                f(sv, svRev, "\(pre)/analytics/coremldata.bin", 243,
                  "5bdb0b132e48c7e852ec18eeba7e217b6cb7153e6a939ce76b5ed17242e956dd"),
                f(sv, svRev, "\(pre)/model.mil", 15_008,
                  "1b9b18be0a35b11165269b1ca071a30af736deb314d8bd82d9540c769137a70e"),
                f(sv, svRev, "\(pre)/weights/weight.bin", 3_037_504,
                  "69c630a115da5e4db36ec41662f0b776c0ef33ec6776d86f8cdaaba022518396"),
                f(vad, vadRev, "\(v)/coremldata.bin", 625,
                  "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41"),
                f(vad, vadRev, "\(v)/analytics/coremldata.bin", 243,
                  "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909"),
                f(vad, vadRev, "\(v)/metadata.json", 3_335,
                  "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6"),
                f(vad, vadRev, "\(v)/model.mil", 176_918,
                  "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270"),
                f(vad, vadRev, "\(v)/weights/weight.bin", 882_304,
                  "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063"),
                f(sv, svRev, "\(enc)/coremldata.bin", 436,
                  "55ef1c194e641418817d7d07f6bfbd8032571e800b81264caba37eb63a95335b"),
                f(sv, svRev, "\(enc)/analytics/coremldata.bin", 243,
                  "ab5e9ee0d49e1f88838f1c2178cbe58a20dac12b50c4da803a75a54c6229845a"),
                f(sv, svRev, "\(enc)/model.mil", 1_134_696,
                  "015fe7242a15eeb2fc0ca7f908ca3a09a5826b36e7d7f704803c8bbe60c1a148"),
                f(sv, svRev, "\(enc)/weights/weight.bin", 235_373_118,
                  "dab122c65d5043cba5b47561d5c1d3a049dd123c662e802d9dbce8fdd0505a38"),
            ])
    }()
}

// MARK: - On-disk layout + checks (pure, testable)

/// What's on disk for one model directory. Files download as `<name>.part`
/// (so an interrupted download resumes from where it stopped), become
/// `<name>` when complete, and the directory counts as installed only once a
/// `.verified` marker records that every file hashed correctly — so the
/// expensive hash runs once, not on every launch.
struct OnDeviceModelLayout {
    let directory: URL
    let files: [OnDeviceModelFile]

    static let markerName = ".verified"

    func finalURL(_ f: OnDeviceModelFile) -> URL { directory.appendingPathComponent(f.name) }
    func partURL(_ f: OnDeviceModelFile) -> URL { directory.appendingPathComponent(f.name + ".part") }
    var markerURL: URL { directory.appendingPathComponent(Self.markerName) }

    /// The marker's content: the hashes it vouches for. A manifest change (new
    /// model revision) therefore invalidates an old install automatically.
    var markerContent: String { files.map { "\($0.name) \($0.sha256)" }.joined(separator: "\n") }

    var isInstalled: Bool {
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              marker == markerContent else { return false }
        return files.allSatisfy { fileSize(finalURL($0)) == $0.size }
    }

    /// Bytes already on disk toward the full download (finished files + partials).
    var bytesOnDisk: Int64 {
        files.reduce(0) { sum, f in
            if let done = fileSize(finalURL(f)) { return sum + min(done, f.size) }
            return sum + min(fileSize(partURL(f)) ?? 0, f.size)
        }
    }

    /// Everything under the directory (what "Delete model" frees).
    var totalBytesInDirectory: Int64 {
        guard let e = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            total += fileSize(url) ?? 0
        }
        return total
    }

    func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return nil }
        return n.int64Value
    }
}

/// Streaming SHA-256 (the model is ~240 MB; never read it into memory whole).
func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Does the file match its manifest entry (size first — cheap — then hash)?
func verify(fileAt url: URL, against f: OnDeviceModelFile) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          (attrs[.size] as? NSNumber)?.int64Value == f.size else { return false }
    return (try? sha256Hex(of: url)) == f.sha256.lowercased()
}

// MARK: - State

public enum OnDeviceModelState: Equatable, Sendable {
    case notInstalled
    case downloading(fraction: Double)
    case verifying
    case installed(bytes: Int64)
    case failed(message: String)

    public var isInstalled: Bool { if case .installed = self { return true } else { return false } }
}

/// The one line the voice gesture shows when an on-device engine is picked
/// but its model can't run yet; nil when it's ready. Says what to do, nothing
/// else (the why lives here: the model is a separate download, not bundled).
public func onDeviceModelUnavailableMessage(for state: OnDeviceModelState) -> String? {
    switch state {
    case .installed:
        return nil
    case .downloading(let fraction):
        return "Downloading speech model… \(Int((fraction * 100).rounded(.down)))%"
    case .verifying:
        return "Checking speech model…"
    case .notInstalled, .failed:
        return "Speech model not downloaded — open Settings → Voice."
    }
}

// MARK: - Store (download / delete / state)

/// Owns the model's lifecycle for the UI: current state, download with
/// progress + cancel + resume, verification, delete. Main-actor state; every
/// byte of I/O (the download, the hash) runs off the main thread.
@MainActor
public final class OnDeviceModelStore: ObservableObject {
    /// One store per catalogue model, shared by the Settings panel and the
    /// voice session so both see the same download.
    public static func shared(for model: OnDeviceASRModel) -> OnDeviceModelStore {
        if let s = registry[model.id] { return s }
        let s = OnDeviceModelStore(model: model)
        registry[model.id] = s
        return s
    }
    private static var registry: [String: OnDeviceModelStore] = [:]

    @Published public private(set) var state: OnDeviceModelState = .notInstalled
    /// Bytes of an interrupted download kept on disk (resume point); 0 if none.
    @Published public private(set) var partialBytes: Int64 = 0

    public let model: OnDeviceASRModel
    public let directory: URL
    let layout: OnDeviceModelLayout
    private var downloadTask: Task<Void, Never>?
    private var downloader: ModelDownloader?

    /// `directory` overrides the model's default location (tests).
    public init(model: OnDeviceASRModel, directory: URL? = nil) {
        self.model = model
        self.directory = directory ?? model.defaultDirectory
        self.layout = OnDeviceModelLayout(directory: self.directory, files: model.files)
        if directory == nil { Self.removeRetiredModels() }
        refresh()
    }

    /// Free what older builds downloaded and nothing reads now, off the main
    /// thread. Once per launch.
    private static var retiredSwept = false
    private static func removeRetiredModels() {
        guard !retiredSwept else { return }
        retiredSwept = true
        let root = OnDeviceASRModel.modelsRoot
        DispatchQueue.global(qos: .utility).async {
            for name in OnDeviceASRModel.retiredDirectoryNames {
                let url = root.appendingPathComponent(name, isDirectory: true)
                if (try? FileManager.default.removeItem(at: url)) != nil {
                    dlog("[on-device-asr] removed retired model \(name)")
                }
            }
        }
    }

    public var totalBytes: Int64 { layout.files.reduce(0) { $0 + $1.size } }

    /// Re-read the disk (a few stats — no hashing).
    public func refresh() {
        if case .downloading = state { return }
        if case .verifying = state { return }
        if layout.isInstalled {
            state = .installed(bytes: layout.totalBytesInDirectory)
            partialBytes = 0
        } else {
            if case .failed = state {} else { state = .notInstalled }
            partialBytes = layout.bytesOnDisk
        }
    }

    public func download() {
        switch state {
        case .downloading, .verifying, .installed: return
        default: break
        }
        let layout = self.layout
        let total = totalBytes
        state = .downloading(fraction: Double(layout.bytesOnDisk) / Double(max(total, 1)))
        let downloader = ModelDownloader()
        self.downloader = downloader
        downloadTask = Task { [weak self] in
            let result = await downloader.run(layout: layout) { done in
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(fraction: Double(done) / Double(max(total, 1)))
                }
            } verifying: {
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .verifying
                }
            }
            guard let self else { return }
            self.downloader = nil
            self.downloadTask = nil
            switch result {
            case .success:
                dlog("[on-device-asr] model installed at \(layout.directory.path)")
                self.state = .installed(bytes: layout.totalBytesInDirectory)
                self.partialBytes = 0
                // Start the one-time Neural Engine compile now (in the
                // background; the CPU copy is usable at once), not on the
                // first hold.
                OnDeviceASREngine.shared.preload(self.model, directory: layout.directory)
            case .cancelled:
                self.state = .notInstalled
                self.partialBytes = layout.bytesOnDisk
            case .failure(let message):
                dlog("[on-device-asr] model download failed: \(message)")
                self.state = .failed(message: message)
                self.partialBytes = layout.bytesOnDisk
            }
        }
    }

    /// Stop the download; what's already on disk is kept so the next
    /// `download()` resumes from there.
    public func cancelDownload() {
        downloader?.cancel()
    }

    /// Remove the model (and any partial download), and drop the loaded copy.
    public func delete() {
        downloader?.cancel()
        OnDeviceASREngine.shared.unload()
        try? FileManager.default.removeItem(at: directory)
        state = .notInstalled
        partialBytes = 0
    }

    /// The files verified but won't load: forget the install (drop the
    /// marker), so the gesture asks for a fresh download instead of failing
    /// on every hold. The files stay; the next download re-verifies them and
    /// replaces any that don't hash.
    public func invalidate() {
        try? FileManager.default.removeItem(at: layout.markerURL)
        state = .failed(message: "Speech model couldn't load — download it again.")
        refresh()
    }
}

// MARK: - Downloader

/// Ranged HTTP download of each manifest file into `<name>.part`, then
/// SHA-256 verification. Runs on its own URLSession delegate queue; nothing
/// here touches the main thread.
final class ModelDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome: Equatable { case success, cancelled, failure(String) }

    private let lock = NSLock()
    private var cancelled = false
    private var current: URLSessionDataTask?
    private var session: URLSession?

    // Per-request state (only touched from the delegate queue).
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Outcome?, Never>?
    private var fileDone: Int64 = 0
    private var baseDone: Int64 = 0
    private var progress: (@Sendable (Int64) -> Void)?
    private var lastReport = Date.distantPast
    private var requestedOffset: Int64 = 0

    func cancel() {
        lock.lock(); cancelled = true; let t = current; lock.unlock()
        t?.cancel()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run(layout: OnDeviceModelLayout,
             progress: @escaping @Sendable (Int64) -> Void,
             verifying: @escaping @Sendable () -> Void) async -> Outcome {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: layout.directory, withIntermediateDirectories: true)
            Self.excludeFromBackup(layout.directory.deletingLastPathComponent())
            Self.excludeFromBackup(layout.directory)
        } catch {
            return .failure("Couldn't save the model — check free space on this device.")
        }
        // A stale marker must not vouch for files we're about to replace.
        try? fm.removeItem(at: layout.markerURL)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        defer { session.invalidateAndCancel() }

        var done: Int64 = 0
        for file in layout.files {
            if isCancelled { return .cancelled }
            let final = layout.finalURL(file)
            if layout.fileSize(final) == file.size { done += file.size; progress(done); continue }
            try? fm.removeItem(at: final)
            var fetched = false
            var lastError = "Download failed — check your connection and try again."
            for url in file.urls {
                if isCancelled { return .cancelled }
                switch await fetch(url: url, to: layout.partURL(file), file: file, base: done, progress: progress) {
                case nil:
                    fetched = true
                case .cancelled?:
                    return .cancelled
                case .failure(let message)?:
                    lastError = message
                case .success?:
                    fetched = true
                }
                if fetched { break }
            }
            guard fetched else { return .failure(lastError) }
            do {
                try fm.moveItem(at: layout.partURL(file), to: final)
            } catch {
                return .failure("Couldn't save the model — check free space on this device.")
            }
            done += file.size
            progress(done)
        }

        verifying()
        for file in layout.files {
            if isCancelled { return .cancelled }
            guard verify(fileAt: layout.finalURL(file), against: file) else {
                // Corrupt: drop it so the next attempt is a clean download, not
                // a resume onto bad bytes.
                try? fm.removeItem(at: layout.finalURL(file))
                try? fm.removeItem(at: layout.partURL(file))
                return .failure("Download was corrupted — try again.")
            }
        }
        do {
            try layout.markerContent.write(to: layout.markerURL, atomically: true, encoding: .utf8)
        } catch {
            return .failure("Couldn't save the model — check free space on this device.")
        }
        return .success
    }

    /// nil = this file is complete in `.part`.
    private func fetch(url: URL, to part: URL, file: OnDeviceModelFile, base: Int64,
                       progress: @escaping @Sendable (Int64) -> Void) async -> Outcome? {
        let fm = FileManager.default
        try? fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        var have = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)??.int64Value ?? 0
        if have > file.size { try? fm.removeItem(at: part); fm.createFile(atPath: part.path, contents: nil); have = 0 }
        if have == file.size { return nil }

        guard let handle = try? FileHandle(forWritingTo: part) else {
            return .failure("Couldn't save the model — check free space on this device.")
        }
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }

        let outcome: Outcome? = await withCheckedContinuation { cont in
            session?.delegateQueue.addOperation {
                self.handle = handle
                self.continuation = cont
                self.fileDone = have
                self.baseDone = base
                self.requestedOffset = have
                self.progress = progress
                guard let task = self.session?.dataTask(with: request) else {
                    self.finish(.failure("Download failed — check your connection and try again."))
                    return
                }
                self.lock.lock(); self.current = task; let c = self.cancelled; self.lock.unlock()
                if c { self.finish(.cancelled); return }
                task.resume()
            }
        }
        try? handle.close()
        guard outcome == nil else { return outcome }
        let size = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)??.int64Value ?? 0
        return size == file.size ? nil : .failure("Download was interrupted — try again to resume.")
    }

    private func finish(_ outcome: Outcome?) {
        lock.lock(); current = nil; lock.unlock()
        let c = continuation
        continuation = nil
        handle = nil
        c?.resume(returning: outcome)
    }

    // MARK: URLSessionDataDelegate (delegate queue, serial)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200  // file:// (tests): a full body
        switch status {
        case 206:
            _ = try? handle?.seekToEnd()
            completionHandler(.allow)
        case 200:
            // The server ignored our Range: start the file over.
            try? handle?.truncate(atOffset: 0)
            fileDone = 0
            completionHandler(.allow)
        case 416 where requestedOffset > 0:
            // Range past the end: the partial is already complete or junk —
            // let the size check after the request decide.
            completionHandler(.cancel)
        default:
            dlog("[on-device-asr] download HTTP \(status) from \(response.url?.host ?? "?")")
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            return
        }
        fileDone += Int64(data.count)
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.2 {
            lastReport = now
            progress?(baseDone + fileDone)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if isCancelled { finish(.cancelled); return }
        if let error, (error as? URLError)?.code != .cancelled {
            dlog("[on-device-asr] download error: \(error.localizedDescription)")
            finish(.failure("Download failed — check your connection and try again."))
            return
        }
        // Success, or we cancelled on a bad status — `fetch` checks the size.
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 200
        if error != nil, status != 416 {
            finish(.failure("Download failed — check your connection and try again."))
            return
        }
        finish(nil)
    }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}
