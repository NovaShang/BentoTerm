import Foundation

/// Transport-agnostic file access for the tap-to-preview feature.
///
/// Detection intelligence stays entirely client-side (PathDetection.swift);
/// a `FilePreviewSource` is only the dumb pipe that resolves + stats + reads
/// bytes on whatever machine the pane is talking to:
///   • macOS local panes  → `LocalFileSource` (direct FileManager)
///   • iOS SSH panes      → Citadel SFTP over the pane's own connection
///                          (app target)
public protocol FilePreviewSource: AnyObject, Sendable {
    /// Resolve `path` (absolute, `~/…`, or relative) against the pane's `cwd`
    /// and stat it. Cheap — used to verify low-confidence candidates before
    /// any UI shows.
    func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat)
    /// Read up to `maxBytes` from the start of the file.
    func read(resolvedPath: String, maxBytes: Int) async throws -> Data
    /// Read up to `length` bytes starting at `offset`. `FileFetch` walks a
    /// whole file through this so progress ticks and a cancel lands between
    /// chunks instead of after the entire transfer.
    func read(resolvedPath: String, offset: UInt64, length: Int) async throws -> Data
    /// True only when the ranged read above really seeks. The default below
    /// emulates it by re-reading the head, which is correct but quadratic over
    /// a whole file — so `FileFetch` fetches non-seeking sources in one shot
    /// (complete, just without progress) rather than chunk them.
    var supportsRangedRead: Bool { get }
    /// One directory's immediate children — the lazy-listing pipe behind
    /// browse expansion and `TreeWalker`'s search walks. A source that can't
    /// list keeps the default, which throws: browse shows an error row and
    /// search degrades to direct resolution.
    func listDirectory(path: String, request: DirectoryListRequest) async throws -> DirectoryListResult
}

public extension FilePreviewSource {
    func listDirectory(path: String, request: DirectoryListRequest) async throws -> DirectoryListResult {
        throw FilePreviewError.unavailable("Directory listing not supported on this connection.")
    }

    var supportsRangedRead: Bool { false }

    func read(resolvedPath: String, offset: UInt64, length: Int) async throws -> Data {
        let start = Int(clamping: offset)
        guard start <= Int.max - length else { return Data() }
        let head = try await read(resolvedPath: resolvedPath, maxBytes: start + length)
        guard head.count > start else { return Data() }
        return head.subdata(in: start ..< min(head.count, start + length))
    }
}

public struct FilePreviewStat: Sendable, Equatable {
    public let size: Int64
    public let isDirectory: Bool
    public let isRegular: Bool
    public let modified: Date?

    public init(size: Int64, isDirectory: Bool, isRegular: Bool, modified: Date?) {
        self.size = size
        self.isDirectory = isDirectory
        self.isRegular = isRegular
        self.modified = modified
    }
}

public enum FilePreviewError: LocalizedError {
    case notFound(String)
    case notAFile(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let p): return "File not found: \(p)"
        case .notAFile(let p): return "Not a regular file: \(p)"
        case .unavailable(let why): return why
        }
    }
}

// MARK: - Directory listing (lazy browse + search pipe)

/// One immediate child of a directory, name relative to that directory.
public struct DirectoryEntry: Sendable, Equatable {
    public let name: String
    public let isDir: Bool

    public init(name: String, isDir: Bool) {
        self.name = name
        self.isDir = isDir
    }
}

/// Client-chosen bounds for a SINGLE directory listing. The old global
/// budgets (depth / total entries) are gone — the unit of listing is one
/// readdir, so depth is unlimited and the only cap left is per-directory.
public struct DirectoryListRequest: Sendable {
    /// Children returned (source-sorted, deterministic). More than this ⇒
    /// `DirectoryListResult.truncated == true` — a caller may re-fetch with a
    /// bigger cap (the cache keys on this, so the re-fetch actually happens).
    public var maxChildren: Int = 200
    /// Generous; one readdir on a slow link is a single round trip. A hanging
    /// source should have its own channel timeouts.
    public var timeBudget: TimeInterval = 5.0

    public init() {}

    public init(maxChildren: Int = 200, timeBudget: TimeInterval = 5.0) {
        self.maxChildren = maxChildren
        self.timeBudget = timeBudget
    }
}

public struct DirectoryListResult: Sendable {
    public let entries: [DirectoryEntry]
    /// True when more children existed than `request.maxChildren` — computed
    /// before prefixing, so a directory with exactly `maxChildren` children
    /// does NOT report truncation.
    public let truncated: Bool

    public init(entries: [DirectoryEntry], truncated: Bool) {
        self.entries = entries
        self.truncated = truncated
    }
}

// MARK: - Pane binding

/// Everything the preview flow needs from the pane a tap landed in, attached
/// at pane-binding time (makeCell on macOS, bindToPaneVM on iOS).
public struct PathPreviewContext: Sendable {
    public let source: FilePreviewSource
    /// The pane's current working directory at tap time (tmux
    /// `#{pane_current_path}`, or the surface's OSC 7 pwd, or nil = unknown →
    /// only absolute / `~` paths resolve).
    public let cwd: @Sendable @MainActor () async -> String?
    /// Shown in the preview header ("This Mac", "user@host").
    public let hostLabel: String
    /// Local files unlock Reveal in Finder / Open on macOS.
    public let isLocal: Bool
    /// Non-nil (a user-facing reason) when `source` CANNOT reach this pane's
    /// files right now, so browsing/preview must honestly refuse instead of
    /// reading the wrong disk. On macOS the source is always local, so a pane
    /// running `ssh`/`mosh` returns a reason here (checked live — you ssh in
    /// and out during one pane's life). nil everywhere the source matches the
    /// pane (all local panes; iOS, whose sources are already remote-aware).
    public let remoteBlock: (@Sendable @MainActor () async -> String?)?

    public init(source: FilePreviewSource,
                cwd: @escaping @Sendable @MainActor () async -> String?,
                hostLabel: String,
                isLocal: Bool,
                remoteBlock: (@Sendable @MainActor () async -> String?)? = nil) {
        self.source = source
        self.cwd = cwd
        self.hostLabel = hostLabel
        self.isLocal = isLocal
        self.remoteBlock = remoteBlock
    }

    /// Foreground commands that mean "the files you're looking at live on
    /// another host" — a local file source would silently read the wrong disk.
    public static func isRemoteShellCommand(_ command: String?) -> Bool {
        guard var c = command, !c.isEmpty else { return false }
        if c.hasPrefix("-") { c.removeFirst() }                 // login-shell dash
        c = (c as NSString).lastPathComponent
        return ["ssh", "mosh", "mosh-client", "autossh", "sshpass", "et", "eternal-terminal"]
            .contains(c)
    }
}

/// Feature flag: Settings toggle, default ON.
public enum PathPreviewSettings {
    public static let key = "path_preview_enabled"
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)
    }
}

// MARK: - Preview payload

public enum FilePreviewContent {
    case text(String, truncated: Bool)
    /// A format the system renders and we don't (pictures, PDF, Office, iWork,
    /// RTF, video, audio, archives, USDZ…) — hand it to Quick Look. The URL is the
    /// file itself when it already lives on this machine; `nil` when the bytes
    /// are still on the remote host, because Quick Look cannot stream and a
    /// whole-file fetch is a size gate + progress + cancel, i.e. UI, not
    /// something `load` may do behind the caller's back.
    case quickLook(URL?)
    /// Not previewable inline (binary, or too large) — header info only.
    case binary
    case directory
}

public struct FilePreviewData {
    public let fileName: String
    public let resolvedPath: String
    public let stat: FilePreviewStat
    public let content: FilePreviewContent
    public let hostLabel: String
    public let isLocal: Bool
    /// `:line` from the tapped token (display only).
    public let line: Int?
    /// The pane context the file came from — lets the renderer resolve
    /// secondary fetches (markdown-relative images) through the same source.
    public let context: PathPreviewContext?
}

public enum FilePreviewLimits {
    /// Text preview reads only the head — plenty to judge a file, bounded on
    /// slow links.
    public static let textBytes = 256 * 1024
}

/// Image formats, extension → MIME. Two callers: the loader routes these to
/// Quick Look (rather than letting the type system send `.svg` to the code
/// renderer), and the web renderer inlines markdown-relative images as data
/// URIs with this MIME — so the two can never drift.
public enum FilePreviewImageMIME {
    public static let table: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml",
        "bmp": "image/bmp", "tiff": "image/tiff", "tif": "image/tiff",
        "ico": "image/x-icon", "heic": "image/heic", "heif": "image/heif",
        "avif": "image/avif",
    ]
}

// MARK: - Loader

public enum FilePreviewLoader {
    /// Resolve → stat → read → classify. Throws `FilePreviewError` (and
    /// whatever transport errors the source surfaces). Resolution goes through
    /// `SmartPathResolver`, so incomplete TUI fragments (bare filename,
    /// repo-root-relative, `…`-truncated) find their file via tree search.
    public static func load(path: String, line: Int?,
                            context: PathPreviewContext) async throws -> FilePreviewData {
        // Honest refusal: the pane is remote but our source is local — don't
        // resolve the tapped path against the wrong (local) disk.
        if let block = context.remoteBlock, let reason = await block() {
            throw FilePreviewError.unavailable(reason)
        }
        let (resolved, st) = try await SmartPathResolver.resolve(path: path, context: context)
        let name = (resolved as NSString).lastPathComponent

        func make(_ content: FilePreviewContent) -> FilePreviewData {
            FilePreviewData(fileName: name, resolvedPath: resolved, stat: st,
                            content: content, hostLabel: context.hostLabel,
                            isLocal: context.isLocal, line: line, context: context)
        }

        if st.isDirectory { return make(.directory) }
        guard st.isRegular else { throw FilePreviewError.notAFile(resolved) }
        if st.size == 0 { return make(.text("", truncated: false)) }

        // Before any read: a format the system previews better than we can —
        // which now includes ordinary pictures. We used to decode those
        // ourselves and draw them, which cost a second renderer to maintain and
        // still could not animate a GIF; Quick Look does both, plus the zoom and
        // pan gestures people already know.
        //
        // The image extension table stays consulted here because `svg` also
        // conforms to `public.xml`, and the type-based route would send it to
        // the code renderer to be read as markup rather than looked at.
        //
        // Deliberately ahead of the head read — pulling 256KB off a 40MB PDF
        // to decide it's binary is a wasted round trip on a slow link.
        let isImageExtension = FilePreviewImageMIME.table[(name as NSString).pathExtension.lowercased()] != nil
        if isImageExtension || QuickLookRouting.prefersQuickLook(fileName: name) {
            return make(.quickLook(context.isLocal ? URL(fileURLWithPath: resolved) : nil))
        }

        let data = try await context.source.read(resolvedPath: resolved,
                                                 maxBytes: FilePreviewLimits.textBytes)
        // An image whose name doesn't say so. Local files hand Quick Look the
        // path; a remote one goes down the same fetch-then-preview path as any
        // other system-rendered file.
        if looksLikeImage(data) {
            return make(.quickLook(context.isLocal ? URL(fileURLWithPath: resolved) : nil))
        }
        return make(classify(data, size: st.size))
    }

    private static func classify(_ data: Data, size: Int64) -> FilePreviewContent {
        // NUL byte in the head → binary, not text.
        if data.prefix(8192).contains(0) { return .binary }
        let text = String(decoding: data, as: UTF8.self)
        return .text(text, truncated: Int64(data.count) < size)
    }

    private static func looksLikeImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }        // PNG
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }                       // JPEG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return true }        // GIF
        if b[0] == 0x42, b[1] == 0x4D { return true }                                    // BMP
        if b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }      // WEBP
        if (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A) ||
           (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A) { return true } // TIFF
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return true }        // HEIC/HEIF (ftyp)
        return false
    }

    public static func sizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Path resolution (shared by sources)

public enum FilePathResolver {
    /// Pure string resolution of `path` against `cwd` / `home`. `~` needs the
    /// target machine's home; when unknown, `~` paths pass through unresolved
    /// (the remote side resolves them). Relative paths without a cwd fail.
    public static func resolve(path: String, cwd: String?, home: String?) throws -> String {
        var p = path
        if p.hasPrefix("~") {
            guard let home, p == "~" || p.hasPrefix("~/") else {
                // "~user/…" or unknown home — let the remote resolve it.
                return p
            }
            p = home + String(p.dropFirst(1))
        }
        if !p.hasPrefix("/") {
            guard let cwd, cwd.hasPrefix("/") else {
                throw FilePreviewError.unavailable("Can't resolve relative path — working directory unknown.")
            }
            p = cwd + "/" + p
        }
        return (p as NSString).standardizingPath
    }
}

// MARK: - Local source (macOS panes; the app is unsandboxed there)

public final class LocalFileSource: FilePreviewSource, @unchecked Sendable {
    public init() {}

    public func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat) {
        let raw = try FilePathResolver.resolve(path: path, cwd: cwd, home: NSHomeDirectory())
        // Follow symlinks so a link-to-file previews as the file it points at.
        let resolved = (raw as NSString).resolvingSymlinksInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw FilePreviewError.notFound(raw)
        }
        let attrs = (try? fm.attributesOfItem(atPath: resolved)) ?? [:]
        return (resolved, FilePreviewStat(
            size: (attrs[.size] as? Int64) ?? 0,
            isDirectory: isDir.boolValue,
            isRegular: (attrs[.type] as? FileAttributeType) == .typeRegular,
            modified: attrs[.modificationDate] as? Date
        ))
    }

    public func read(resolvedPath: String, maxBytes: Int) async throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: resolvedPath) else {
            throw FilePreviewError.notFound(resolvedPath)
        }
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes) ?? Data()
    }

    public var supportsRangedRead: Bool { true }

    /// Re-opening per chunk would be silly for a local disk — but nothing
    /// chunks a local file: `FileFetch` hands out the real path instead of
    /// copying it. This exists so the protocol is honestly implemented.
    public func read(resolvedPath: String, offset: UInt64, length: Int) async throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: resolvedPath) else {
            throw FilePreviewError.notFound(resolvedPath)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }

    public func listDirectory(path: String, request: DirectoryListRequest) async throws -> DirectoryListResult {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(atPath: path) else {
            throw FilePreviewError.notFound(path)
        }
        // truncation computed BEFORE prefixing (exactly-maxChildren is not truncation)
        let truncated = all.count > request.maxChildren
        let sorted = all.sorted()
        var out: [DirectoryEntry] = []
        out.reserveCapacity(min(sorted.count, request.maxChildren))
        for name in sorted.prefix(request.maxChildren) {
            let childAbs = (path as NSString).appendingPathComponent(name)
            var isDirObj: ObjCBool = false
            guard fm.fileExists(atPath: childAbs, isDirectory: &isDirObj) else { continue }
            // A symlinked directory is reported but never treated as a real
            // directory (loop safety when a walk descends); attributesOfItem
            // does not follow links.
            let isLink = (try? fm.attributesOfItem(atPath: childAbs)[.type])
                .flatMap { $0 as? FileAttributeType } == .typeSymbolicLink
            out.append(DirectoryEntry(name: name, isDir: isDirObj.boolValue && !isLink))
        }
        return DirectoryListResult(entries: out, truncated: truncated)
    }
}
