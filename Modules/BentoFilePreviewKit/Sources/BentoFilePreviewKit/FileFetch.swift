import Foundation
import CryptoKit

public enum FileFetchLimits {
    /// Above this a remote fetch asks first. Below it the wait is short enough
    /// that a confirmation is just a click in the way.
    public static let confirmAbove: Int64 = 25 * 1024 * 1024
    /// Refused outright — a transfer this size over an interactive SSH channel
    /// is not a preview, it is scp.
    public static let hardMax: Int64 = 2 * 1024 * 1024 * 1024
    /// Chunk of one ranged read: big enough that per-chunk overhead vanishes,
    /// small enough that a cancel lands promptly and progress moves visibly.
    static let chunkBytes = 512 * 1024
    /// How long a downloaded copy stays reusable. Deleting on dismissal is the
    /// obvious move and it races: some share targets read the URL *after* the
    /// sheet goes away. Nothing here is deleted while it might still be in
    /// use — the sweep only ever drops entries older than this.
    static let tempTTL: TimeInterval = 6 * 60 * 60
}

public enum FileFetchError: LocalizedError {
    case tooLarge(Int64)
    case incomplete(expected: Int64, got: Int64)
    case notFetchable

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes):
            return "\(FilePreviewLoader.sizeLabel(bytes)) is over the \(FilePreviewLoader.sizeLabel(FileFetchLimits.hardMax)) download limit."
        case .incomplete(let expected, let got):
            return "Only \(FilePreviewLoader.sizeLabel(got)) of \(FilePreviewLoader.sizeLabel(expected)) arrived — check whether the file is still being written."
        case .notFetchable:
            return "This file can't be downloaded from here."
        }
    }
}

/// Everything a fetch needs, taken straight off the resolved file. Built from
/// a `FilePreviewData` but deliberately NOT holding one: the rendered content
/// is a capped head read, and no code path may ever be able to reach for it as
/// a shortcut.
public struct FileFetchRequest: Sendable {
    public let source: FilePreviewSource
    public let resolvedPath: String
    public let fileName: String
    public let size: Int64
    public let modified: Date?
    public let hostLabel: String
    /// Local files are handed over by path — no copy, no size gate.
    public let isLocal: Bool

    public init(source: FilePreviewSource, resolvedPath: String, fileName: String,
                size: Int64, modified: Date?, hostLabel: String, isLocal: Bool) {
        self.source = source
        self.resolvedPath = resolvedPath
        self.fileName = fileName
        self.size = size
        self.modified = modified
        self.hostLabel = hostLabel
        self.isLocal = isLocal
    }

    /// nil when the file can't be fetched at all: a directory, or a preview
    /// that arrived without its pane context (no source to read through).
    public init?(_ data: FilePreviewData) {
        guard let source = data.context?.source, data.stat.isRegular else { return nil }
        self.init(source: source, resolvedPath: data.resolvedPath, fileName: data.fileName,
                  size: data.stat.size, modified: data.stat.modified,
                  hostLabel: data.hostLabel, isLocal: data.isLocal)
    }

    /// True when the transfer is big enough to ask about first.
    public var needsConfirmation: Bool {
        !isLocal && size > FileFetchLimits.confirmAbove
    }
}

/// The one path that turns "a file on some host" into "a complete file at a
/// local URL". Two callers need exactly that and neither can work with less:
/// Quick Look takes only a URL, and the share sheet takes only a URL — where a
/// SHORT one is silent data loss, a file with the right name quietly missing
/// everything past the preview's 256KB read cap.
///
/// So this is the only place allowed to produce that URL, it never sees what a
/// preview already loaded (`FileFetchRequest` carries the path and the stat,
/// never `FilePreviewContent`), and a copy reaches the name a share could hand
/// out only after its byte count matched the stat.
public enum FileFetch {

    /// A complete local copy of `request`, or the file itself when it is
    /// already local. Never partial: the download writes to a hidden name and
    /// is renamed into place only after the byte count matches.
    ///
    /// Runs entirely off the main actor (nonisolated + async); `onProgress`
    /// fires on whatever executor the read landed on, so a UI caller must hop
    /// back itself.
    public static func localCopy(
        of request: FileFetchRequest,
        onProgress: @Sendable @escaping (_ received: Int64, _ total: Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        if request.isLocal { return URL(fileURLWithPath: request.resolvedPath) }
        guard request.size <= FileFetchLimits.hardMax else {
            throw FileFetchError.tooLarge(request.size)
        }

        let fm = FileManager.default
        let dir = cacheDirectory(for: request)
        let destination = dir.appendingPathComponent(safeName(request.fileName))

        // Re-previewing (or sharing what was just previewed) reuses the copy
        // instead of pulling the file down twice. Only complete copies ever
        // get this far, and the key covers size + mtime, so a file edited on
        // the host misses the cache rather than serving a stale body.
        if let existing = try? fm.attributesOfItem(atPath: destination.path),
           (existing[.size] as? NSNumber)?.int64Value == request.size {
            onProgress(request.size, request.size)
            return destination
        }

        sweepStaleCopies()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Downloads land on a name nothing shares and nothing shows. A crash
        // or a cancel therefore leaves litter for the sweep, never a truncated
        // file sitting at the name the share sheet would hand out.
        let partial = dir.appendingPathComponent(".incomplete-\(UUID().uuidString)")
        fm.createFile(atPath: partial.path, contents: nil)
        do {
            let received = try await download(request, to: partial, onProgress: onProgress)
            guard received == request.size else {
                throw FileFetchError.incomplete(expected: request.size, got: received)
            }
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            try fm.moveItem(at: partial, to: destination)
            return destination
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// Streams the file to disk. Bytes go straight from the read to the file
    /// handle — a 500MB video must not become a 500MB `Data` in memory first.
    private static func download(
        _ request: FileFetchRequest, to url: URL,
        onProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> Int64 {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        guard request.source.supportsRangedRead else {
            // No seek: one shot is the only complete read available. Progress
            // can't tick, which is why the UI shows an indeterminate bar
            // rather than a lying percentage.
            let whole = try await request.source.read(resolvedPath: request.resolvedPath,
                                                      maxBytes: Int(clamping: request.size))
            try handle.write(contentsOf: whole)
            let count = Int64(whole.count)
            onProgress(count, request.size)
            return count
        }

        var received: Int64 = 0
        while received < request.size {
            try Task.checkCancellation()
            let want = Int(min(Int64(FileFetchLimits.chunkBytes), request.size - received))
            let chunk = try await request.source.read(resolvedPath: request.resolvedPath,
                                                     offset: UInt64(received), length: want)
            // EOF before the stat's size: the file shrank, or was still being
            // written when we statted it. Bailing out here leaves
            // `received < size`, which the caller turns into an error — the
            // one thing that must not happen is quietly keeping the short
            // file.
            guard !chunk.isEmpty else { break }
            try handle.write(contentsOf: chunk)
            received += Int64(chunk.count)
            onProgress(received, request.size)
        }
        return received
    }

    // MARK: - Temp storage

    /// Root for every downloaded copy, so the sweep can never wander into a
    /// directory it doesn't own.
    private static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BentoFileFetch", isDirectory: true)
    }

    /// One directory per (host, path, size, mtime) holding one file under its
    /// REAL name — a receiving app shows the name it is given, and a
    /// UUID-named file exports as garbage. Uniqueness therefore has to live in
    /// the directory.
    private static func cacheDirectory(for request: FileFetchRequest) -> URL {
        let stamp = request.modified.map { String(Int64($0.timeIntervalSince1970)) } ?? "-"
        let key = "\(request.hostLabel)\u{0}\(request.resolvedPath)\u{0}\(request.size)\u{0}\(stamp)"
        let digest = SHA256.hash(data: Data(key.utf8))
            .prefix(10).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    /// A basename is `lastPathComponent`, so it can't contain a separator —
    /// but it can be empty or a dot entry, which would name the directory
    /// itself.
    private static func safeName(_ name: String) -> String {
        (name.isEmpty || name == "." || name == "..") ? "file" : name
    }

    /// Drop copies older than the TTL. Runs on the fetch path (already off the
    /// main actor) rather than at launch, so the directory a share is reading
    /// right now was, by definition, touched within the TTL.
    private static func sweepStaleCopies() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-FileFetchLimits.tempTTL)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fm.removeItem(at: entry)
        }
    }
}

// MARK: - UI state

/// Drives the fetch for a view: the size gate, the progress the wait needs to
/// not read as a hang, and a cancel. Shared by the Quick Look panel and the
/// share button so both gates behave identically.
@MainActor
public final class FileFetchModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        /// Waiting for the user to accept a big transfer.
        case confirming(bytes: Int64)
        /// `total == 0` for a source that can't report progress.
        case fetching(received: Int64, total: Int64)
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?
    private var pending: (FileFetchRequest, (URL) -> Void)?

    public init() {}

    public var isBusy: Bool {
        if case .fetching = phase { return true }
        return false
    }

    /// Ask for a local copy. `completion` runs on the main actor, once, and
    /// only with a complete file.
    public func request(_ request: FileFetchRequest, completion: @escaping (URL) -> Void) {
        guard !isBusy else { return }
        if request.needsConfirmation {
            pending = (request, completion)
            phase = .confirming(bytes: request.size)
        } else {
            start(request, completion)
        }
    }

    public func confirm() {
        guard let (request, completion) = pending else { return }
        pending = nil
        start(request, completion)
    }

    public func cancel() {
        task?.cancel()
        task = nil
        pending = nil
        phase = .idle
    }

    private func start(_ request: FileFetchRequest, _ completion: @escaping (URL) -> Void) {
        task?.cancel()
        phase = .fetching(received: 0, total: request.isLocal ? 0 : request.size)
        task = Task { [weak self] in
            do {
                let url = try await FileFetch.localCopy(of: request) { received, total in
                    Task { @MainActor [weak self] in self?.tick(received, total) }
                }
                guard !Task.isCancelled else { return }
                self?.phase = .idle
                completion(url)
            } catch is CancellationError {
                // cancel() already put the phase back; a cancelled transfer is
                // not an error to report.
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Late ticks from an abandoned transfer must not resurrect a progress bar
    /// the user cancelled — only a running fetch advances.
    private func tick(_ received: Int64, _ total: Int64) {
        guard case .fetching = phase else { return }
        phase = .fetching(received: received, total: total)
    }
}
