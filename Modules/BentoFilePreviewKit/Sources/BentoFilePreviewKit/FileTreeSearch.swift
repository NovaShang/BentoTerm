import Foundation
import os

/// Diagnostics for the whole tap-to-preview pipeline (detection → candidates
/// → resolution). Fires only on tap/⌘click, so it's always on; content lines
/// are logged .public — it's the user's own terminal on their own machine.
/// Watch with: log stream --predicate 'category == "PathPreview"'
public let pathPreviewLog = Logger(subsystem: "com.novashang.bento", category: "PathPreview")

/// Bounded file-tree search that turns incomplete TUI path fragments into
/// real files, for tap-to-preview.
///
/// TUI agents rarely print complete paths: bare filenames ("BentoApp.swift"),
/// repo-root-relative paths while the pane sits in a subdirectory, `…`-
/// truncated prefixes, hard-wrap join guesses. `SmartPathResolver` resolves
/// them in escalating passes: direct stat → budgeted lazy search of the tree
/// under the pane's cwd (`TreeWalker` over per-directory listings — no
/// pre-listed index anymore) → cwd's ancestors. All matching/ranking
/// intelligence stays client-side; a `FilePreviewSource` only provides the
/// dumb `listDirectory` pipe (transport-independence rule).

/// One entry of a tree walk or search result, relative to the walk root.
public struct FileTreeEntry: Sendable, Equatable {
    public let relPath: String
    public let isDir: Bool

    public init(relPath: String, isDir: Bool) {
        self.relPath = relPath
        self.isDir = isDir
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

    /// Tap-search budget: one tap, one quiet miss. Tight enough that a missed
    /// search stays under a heartbeat on a slow link; loose enough to find
    /// deep files. SFTP gets parallelism — one round trip per directory, so
    /// 8 outstanding readdirs collapse the RTT term.
    static func tapSearchRequest(isLocal: Bool) -> SearchRequest {
        isLocal
            ? SearchRequest(maxDirs: 256, timeBudget: 1.0)
            : SearchRequest(maxDirs: 128, timeBudget: 1.5, parallelism: 8)
    }

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
            // Pass 2: budgeted lazy search under cwd. The old pre-listed index
            // (depth ≤ 4 / 2000 entries) is gone — `TreeWalker` walks
            // directories on demand through DirectoryListCache, which IS the
            // incremental index: the first walk's directories make the second
            // candidate's walk nearly free. A walk cut off by its budget is
            // treated as a silent miss (the tap stays quiet; logged).
            var cutOff: (dirs: Int, root: String)?
            do {
                let budget = Self.tapSearchRequest(isLocal: context.isLocal)
                for (i, p) in searchable.prefix(2) {
                    var req = budget
                    req.maxDirs = max(8, budget.maxDirs / 2)
                    let outcome = try await TreeWalker.search(
                        source: context.source, root: cwd, query: normalized(p), request: req)
                    pathPreviewLog.log("search query=\(normalized(p), privacy: .public) dirs=\(outcome.dirsVisited) partial=\(outcome.partial) matches=\(outcome.entries.count)")
                    for m in outcome.entries.prefix(2) {
                        if let r = try? await context.source.stat(path: cwd + "/" + m.relPath, cwd: cwd) {
                            pathPreviewLog.log("resolved via search [\(i)] → \(r.resolvedPath, privacy: .public)")
                            return Resolution(index: i, resolvedPath: r.resolvedPath, stat: r.stat)
                        }
                    }
                    if outcome.partial { cutOff = (outcome.dirsVisited, cwd) }
                }
            } catch {
                pathPreviewLog.log("lazy search unavailable: \(String(describing: error), privacy: .public)")
            }
            if let cutOff {
                pathPreviewLog.log("search cut off after \(cutOff.dirs, privacy: .public) directories under \(cutOff.root, privacy: .public) — the tapped fragment may exist deeper")
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
