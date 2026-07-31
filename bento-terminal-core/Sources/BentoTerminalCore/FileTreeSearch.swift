import Foundation
import os

/// Diagnostics for the whole tap-to-preview pipeline (detection → candidates
/// → resolution). Fires only on tap/⌘click, so it's always on; content lines
/// are logged .public — it's the user's own terminal on their own machine.
/// Watch with: log stream --predicate 'category == "PathPreview"'
let pathPreviewLog = Logger(subsystem: "com.novashang.bento", category: "PathPreview")

/// Bounded file-tree search that turns incomplete TUI path fragments into
/// real files, for tap-to-preview.
///
/// TUI agents rarely print complete paths: bare filenames ("BentoApp.swift"),
/// repo-root-relative paths while the pane sits in a subdirectory, `…`-
/// truncated prefixes, hard-wrap join guesses. `SmartPathResolver` resolves
/// them in escalating passes: direct stat → bounded index of the tree under
/// the pane's cwd → cwd's ancestors. All matching/ranking intelligence stays
/// client-side; a `FilePreviewSource` only provides the dumb `listTree` pipe
/// (transport-independence rule).

/// One entry of a bounded tree listing, relative to the listing root.
public struct FileTreeEntry: Sendable, Equatable {
    public let relPath: String
    public let isDir: Bool

    public init(relPath: String, isDir: Bool) {
        self.relPath = relPath
        self.isDir = isDir
    }
}

/// Client-chosen bounds for a tree listing. Each source enforces these
/// mechanically as it walks; the policy lives here, so a slow SFTP link and a
/// local FileManager walk are held to the same budget.
public struct TreeListRequest: Sendable {
    public var maxDepth = 4
    public var maxEntries = 2000
    /// Directory-visit cap for sources that walk with one round trip per
    /// directory (SFTP) — keeps slow links bounded.
    public var maxDirs = 256
    /// Children listed per directory (sorted, so deterministic). One giant
    /// flat directory must not eat the whole entry budget.
    public var maxChildrenPerDir = 200
    public var timeBudget: TimeInterval = 1.5
    public var skipNames = TreeListRequest.defaultSkipNames

    /// Directories never descended into. Entries starting with `*` match by
    /// suffix ("*.noindex"); everything else matches the exact name. Heavy,
    /// machine-generated trees would otherwise drown the entry budget — a
    /// live repo with an Xcode build/ dir burned all 2000 entries before the
    /// walk ever reached the source tree.
    public static let defaultSkipNames: Set<String> = [
        ".git", "node_modules", ".build", ".swiftpm", "DerivedData", "Pods",
        "__pycache__", ".venv", "venv", ".cache", ".next", ".gradle", "target",
        "Build", "XCBuildData", "SourcePackages", "EagerLinkingTBDs",
        "SwiftExplicitPrecompiledModules", "ModuleCache", "dist", ".Trash",
        "*.noindex", "*.app", "*.xcarchive", "*.framework", "*.xcframework",
        "*.dSYM",
    ]

    public init() {}

    /// Whether a directory named `name` should not be descended into.
    public func skips(_ name: String) -> Bool {
        if skipNames.contains(name) { return true }
        for pattern in skipNames where pattern.hasPrefix("*") {
            if name.hasSuffix(pattern.dropFirst()) { return true }
        }
        return false
    }
}

// MARK: - Matching / ranking (pure, unit-tested)

public enum PathSearchEngine {
    /// Ranked relative paths from `entries` matching `query`.
    ///
    /// Multi-component queries ("src/main.rs") match on a component-boundary
    /// suffix; single-component queries ("README.md") match the basename
    /// exactly. Ranking prefers matches closer to the root (fewer extra
    /// leading components), then shallower, then shorter, then alphabetical.
    /// A case-insensitive pass runs only when the exact pass finds nothing.
    public static func match(query: String, entries: [FileTreeEntry], limit: Int = 8) -> [String] {
        var q = query
        while q.hasPrefix("./") { q.removeFirst(2) }
        var namedDir = false
        if q.hasSuffix("/") { q.removeLast(); namedDir = true }
        guard !q.isEmpty, !q.hasPrefix("/"), !q.hasPrefix("~"),
              !q.split(separator: "/").contains("..") else { return [] }
        let comps = q.split(separator: "/")
        guard !comps.isEmpty else { return [] }

        func pass(caseFold: Bool) -> [String] {
            func norm(_ s: Substring) -> String { caseFold ? s.lowercased() : String(s) }
            let want = comps.map(norm)
            var scored: [(score: (Int, Int, Int, String), path: String)] = []
            for e in entries {
                let ec = e.relPath.split(separator: "/")
                guard ec.count >= comps.count,
                      ec.suffix(comps.count).map(norm) == want else { continue }
                // Bare-name queries almost always mean a file; directories
                // rank behind unless the query said "name/".
                let dirPenalty = (comps.count == 1 && !namedDir && e.isDir) ? 1 : 0
                scored.append(((ec.count - comps.count, dirPenalty, ec.count, e.relPath),
                               e.relPath))
            }
            return scored.sorted { $0.score < $1.score }.map(\.path)
        }

        // Last resort: FRAGMENT matching against basenames. Terminal wrap and
        // truncation hand the tap a fragment of a real name — the extension
        // half of a spaced filename ("V2.0.docx"), a wrap-eaten-space
        // concatenation ("装饰…要求V2.0.docx"), a clipped tail ("ain.rs"), the
        // extensionless front half — and the index knows every real file, so a
        // not-found here would be a lie. Space-stripped, case-folded exact /
        // suffix / prefix matching, ranked exact > suffix > prefix, files
        // before dirs, shallow first, closest-length first.
        func fragmentPass() -> [String] {
            func fold(_ s: some StringProtocol) -> String {
                s.lowercased().replacingOccurrences(of: " ", with: "")
            }
            guard let lastComp = comps.last else { return [] }
            let q = fold(lastComp)
            guard q.count >= 2 else { return [] }
            var scored: [(score: (Int, Int, Int, Int, String), path: String)] = []
            for e in entries {
                let bn = fold(e.relPath.split(separator: "/").last ?? "")
                let kind: Int
                if bn == q { kind = 0 }
                else if bn.hasSuffix(q) { kind = 1 }
                else if bn.hasPrefix(q) { kind = 2 }
                else { continue }
                let depth = e.relPath.split(separator: "/").count
                scored.append(((kind, e.isDir ? 1 : 0, depth, bn.count, e.relPath),
                               e.relPath))
            }
            return scored.sorted { $0.score < $1.score }.map(\.path)
        }

        var out = pass(caseFold: false)
        if out.isEmpty { out = pass(caseFold: true) }
        if out.isEmpty { out = fragmentPass() }
        return Array(out.prefix(limit))
    }
}

// MARK: - Index cache

/// One bounded tree listing per (source, root), cached briefly so a burst of
/// taps (or the chip → sheet double resolution) scans the tree once. A source
/// that can't list — the `FilePreviewSource.listTree` default throws — is
/// negative-cached so every tap doesn't re-probe it.
public actor FileTreeIndexCache {
    public static let shared = FileTreeIndexCache()

    private struct Key: Hashable {
        let source: ObjectIdentifier
        let root: String
    }

    private var cache: [Key: (entries: [FileTreeEntry], builtAt: CFAbsoluteTime)] = [:]
    private var failed: [Key: CFAbsoluteTime] = [:]
    private var inFlight: [Key: Task<[FileTreeEntry], Error>] = [:]
    private static let ttl: CFAbsoluteTime = 20
    private static let failedTTL: CFAbsoluteTime = 60

    public func entries(source: FilePreviewSource, root: String,
                        request: TreeListRequest = TreeListRequest()) async throws -> [FileTreeEntry] {
        let key = Key(source: ObjectIdentifier(source), root: root)
        let now = CFAbsoluteTimeGetCurrent()
        if let hit = cache[key], now - hit.builtAt < Self.ttl { return hit.entries }
        if let failedAt = failed[key], now - failedAt < Self.failedTTL {
            throw FilePreviewError.unavailable("Tree listing unavailable.")
        }
        if let task = inFlight[key] { return try await task.value }
        let source = source
        let task = Task { try await source.listTree(root: root, request: request) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let entries = try await task.value
            if cache.count >= 8 { cache.removeAll() }   // taps are bursty; tiny cache
            cache[key] = (entries, CFAbsoluteTimeGetCurrent())
            failed[key] = nil
            return entries
        } catch {
            failed[key] = CFAbsoluteTimeGetCurrent()
            throw error
        }
    }
}

// MARK: - Resolver

public enum SmartPathResolver {
    public struct Resolution: Sendable {
        /// Which of the input candidates resolved.
        public let index: Int
        public let resolvedPath: String
        public let stat: FilePreviewStat
    }

    /// How far above cwd the ancestor pass probes (repo-root-relative output
    /// from a pane sitting in a subdirectory).
    static let maxAncestorLevels = 4

    /// Single-path resolution with search fallback — what the preview loader
    /// uses. Absolute and `~` paths resolve directly only.
    public static func resolve(path: String, context: PathPreviewContext) async throws
        -> (resolvedPath: String, stat: FilePreviewStat) {
        let r = try await resolveFirst(paths: [path], context: context)
        return (r.resolvedPath, r.stat)
    }

    /// Resolve the FIRST existing path among ordered candidates (wrap-chain
    /// joins come longest-first). Passes are global — every candidate gets a
    /// direct stat before any tree search — so a cheap exact hit always beats
    /// an expensive fuzzy one. `rootHints` (directories gleaned from absolute
    /// paths near the tap) are the last resort, for panes whose shell cwd
    /// isn't where the agent actually works.
    public static func resolveFirst(paths: [String], rootHints: [String] = [],
                                    context: PathPreviewContext) async throws -> Resolution {
        guard !paths.isEmpty else { throw FilePreviewError.notFound("") }
        let cwd = await context.cwd()
        pathPreviewLog.log("resolveFirst cwd=\(cwd ?? "<nil>", privacy: .public) candidates=\(paths.description, privacy: .public) hints=\(rootHints.description, privacy: .public)")
        var firstError: Error?

        // Pass 1: direct resolution (absolute, ~/…, cwd-relative).
        for (i, p) in paths.enumerated() {
            do {
                let (rp, st) = try await context.source.stat(path: p, cwd: cwd)
                pathPreviewLog.log("resolved direct [\(i)] → \(rp, privacy: .public)")
                return Resolution(index: i, resolvedPath: rp, stat: st)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        let searchable = paths.enumerated().filter { isSearchable($0.element) }
        if let cwd, cwd.hasPrefix("/"), !searchable.isEmpty {
            // Pass 2: bounded index of the tree under cwd. The index entries
            // were just listed, so the first confirming stat almost always
            // lands — it doubles as fetching the stat the preview needs.
            do {
                let entries = try await FileTreeIndexCache.shared.entries(
                    source: context.source, root: cwd)
                pathPreviewLog.log("index root=\(cwd, privacy: .public) entries=\(entries.count)")
                for (i, p) in searchable {
                    for m in PathSearchEngine.match(query: normalized(p), entries: entries).prefix(2) {
                        if let r = try? await context.source.stat(path: cwd + "/" + m, cwd: cwd) {
                            pathPreviewLog.log("resolved via index [\(i)] → \(r.resolvedPath, privacy: .public)")
                            return Resolution(index: i, resolvedPath: r.resolvedPath, stat: r.stat)
                        }
                    }
                }
            } catch {
                pathPreviewLog.log("index unavailable: \(String(describing: error), privacy: .public)")
            }
            // Pass 3: ancestors of cwd, top candidates only.
            for (i, p) in searchable.prefix(2) {
                var dir = cwd
                for _ in 0..<maxAncestorLevels {
                    let parent = (dir as NSString).deletingLastPathComponent
                    guard parent.count > 1, parent != dir else { break }
                    dir = parent
                    if let r = try? await context.source.stat(path: dir + "/" + normalized(p), cwd: nil) {
                        pathPreviewLog.log("resolved via ancestor [\(i)] → \(r.resolvedPath, privacy: .public)")
                        return Resolution(index: i, resolvedPath: r.resolvedPath, stat: r.stat)
                    }
                }
            }
        }
        // Pass 4: screen-context roots. The shell's cwd can simply be the
        // wrong place (agent launched in one directory, editing a project in
        // another) — but absolute paths in the agent's own output name the
        // real root. Purely stat-gated, so a wrong hint costs one probe.
        for root in rootHints.prefix(6) {
            for (i, p) in searchable.prefix(2) {
                if let r = try? await context.source.stat(path: root + "/" + normalized(p), cwd: cwd) {
                    pathPreviewLog.log("resolved via root hint \(root, privacy: .public) [\(i)] → \(r.resolvedPath, privacy: .public)")
                    return Resolution(index: i, resolvedPath: r.resolvedPath, stat: r.stat)
                }
            }
        }
        pathPreviewLog.log("resolveFirst FAILED: \(String(describing: firstError), privacy: .public)")
        throw firstError ?? FilePreviewError.notFound(paths[0])
    }

    /// Tree search only makes sense for plain relative fragments. `..`
    /// segments are direct-resolution territory.
    static func isSearchable(_ p: String) -> Bool {
        !p.hasPrefix("/") && !p.hasPrefix("~")
            && !p.split(separator: "/").contains("..")
    }

    static func normalized(_ p: String) -> String {
        var q = p
        while q.hasPrefix("./") { q.removeFirst(2) }
        return q
    }
}
