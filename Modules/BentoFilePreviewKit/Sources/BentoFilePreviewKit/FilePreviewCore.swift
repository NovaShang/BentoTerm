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
    /// Bounded recursive listing under `root` (absolute), entries relative to
    /// it — the dumb pipe behind `SmartPathResolver`'s tree search. Sources
    /// that can't list keep the default, which throws: the resolver degrades
    /// to direct resolution.
    func listTree(root: String, request: TreeListRequest) async throws -> [FileTreeEntry]
}

public extension FilePreviewSource {
    func listTree(root: String, request: TreeListRequest) async throws -> [FileTreeEntry] {
        throw FilePreviewError.unavailable("Tree listing not supported on this connection.")
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
    case image(Data)
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
    /// Full-image cap; beyond this the preview degrades to info-only.
    public static let imageBytes = 20 * 1024 * 1024
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

        let wantsImage = Self.imageExtensions.contains((name as NSString).pathExtension.lowercased())
        if wantsImage && st.size <= FilePreviewLimits.imageBytes {
            let data = try await context.source.read(resolvedPath: resolved,
                                                     maxBytes: FilePreviewLimits.imageBytes)
            if looksLikeImage(data) { return make(.image(data)) }
            return make(classify(data, size: st.size))
        }

        let data = try await context.source.read(resolvedPath: resolved,
                                                 maxBytes: FilePreviewLimits.textBytes)
        if looksLikeImage(data), st.size <= FilePreviewLimits.imageBytes {
            // Image without a telling extension: refetch in full only if the
            // head read didn't already cover it.
            if data.count >= st.size { return make(.image(data)) }
            let full = try await context.source.read(resolvedPath: resolved,
                                                     maxBytes: FilePreviewLimits.imageBytes)
            return make(.image(full))
        }
        return make(classify(data, size: st.size))
    }

    private static func classify(_ data: Data, size: Int64) -> FilePreviewContent {
        // NUL byte in the head → binary, not text.
        if data.prefix(8192).contains(0) { return .binary }
        let text = String(decoding: data, as: UTF8.self)
        return .text(text, truncated: Int64(data.count) < size)
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif", "ico",
    ]

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

    public func listTree(root: String, request: TreeListRequest) async throws -> [FileTreeEntry] {
        let fm = FileManager.default
        var out: [FileTreeEntry] = []
        var queue: [(rel: String, depth: Int)] = [("", 0)]
        var dirsVisited = 0
        let deadline = CFAbsoluteTimeGetCurrent() + request.timeBudget
        while !queue.isEmpty {
            guard dirsVisited < request.maxDirs,
                  CFAbsoluteTimeGetCurrent() < deadline else { break }
            let (rel, depth) = queue.removeFirst()
            dirsVisited += 1
            let dir = rel.isEmpty ? root : root + "/" + rel
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted().prefix(request.maxChildrenPerDir) {
                guard out.count < request.maxEntries else { return out }
                let childRel = rel.isEmpty ? name : rel + "/" + name
                let childAbs = dir + "/" + name
                var isDirObj: ObjCBool = false
                guard fm.fileExists(atPath: childAbs, isDirectory: &isDirObj) else { continue }
                // A symlinked directory is listed but never descended into
                // (loop safety); attributesOfItem does not follow links.
                let isLink = (try? fm.attributesOfItem(atPath: childAbs)[.type])
                    .flatMap { $0 as? FileAttributeType } == .typeSymbolicLink
                let isDir = isDirObj.boolValue && !isLink
                out.append(FileTreeEntry(relPath: childRel, isDir: isDir))
                if isDir, depth + 1 < request.maxDepth, !request.skips(name) {
                    queue.append((childRel, depth + 1))
                }
            }
        }
        return out
    }
}
