import Foundation

/// Search-time bounds for a lazy tree walk (`TreeWalker`).
///
/// The old `TreeListRequest` capped a whole-subtree pre-listing (depth ≤ 4,
/// ≤ 2000 entries) that browse and search shared. Browse is now lazy (one
/// readdir per expanded directory, no budget at all), so these budgets belong
/// to SEARCH only. `skipNames` moves here unchanged — search still refuses
/// heavy machine-generated trees (a live repo's build/ dir once burned the
/// whole entry budget).
public struct SearchRequest: Sendable {
    /// Directories visited before the walk reports `partial`.
    public var maxDirs = 256
    /// Children listed per directory (source-sorted, so deterministic).
    public var maxChildrenPerDir = 200
    /// Wall-clock budget; a partial result is still a useful result.
    public var timeBudget: TimeInterval = 1.5
    /// Concurrent `listDirectory` calls per BFS wave. 1 for FileManager (a
    /// local readdir is cheap); 8 for SFTP, where one round trip per
    /// directory is the whole cost — pipelining collapses 256 RTTs into
    /// ~16 waves.
    public var parallelism = 1
    /// Rank cap for `search` results.
    public var maxResults = 32
    /// Hard cap on collected candidates; exceeding it marks the outcome
    /// `partial` and stops the walk (more dirs couldn't improve the capped
    /// set). Do NOT "improve" this with early trimming — BFS order plus the
    /// engine's exact→case-fold→fragment pass ordering makes trimming
    /// incorrect (a deeper file can outrank a shallower dir).
    public var collectCap = 1024
    public var skipNames = SearchRequest.defaultSkipNames

    /// Directories never descended into. Entries starting with `*` match by
    /// suffix ("*.noindex"); everything else matches the exact name. Heavy,
    /// machine-generated trees would otherwise eat the whole dir/time budget.
    public static let defaultSkipNames: Set<String> = [
        ".git", "node_modules", ".build", ".swiftpm", "DerivedData", "Pods",
        "__pycache__", ".venv", "venv", ".cache", ".next", ".gradle", "target",
        "Build", "XCBuildData", "SourcePackages", "EagerLinkingTBDs",
        "SwiftExplicitPrecompiledModules", "ModuleCache", "dist", ".Trash",
        "*.noindex", "*.app", "*.xcarchive", "*.framework", "*.xcframework",
        "*.dSYM",
    ]

    public init() {}

    public init(maxDirs: Int = 256, maxChildrenPerDir: Int = 200,
                timeBudget: TimeInterval = 1.5, parallelism: Int = 1,
                maxResults: Int = 32, collectCap: Int = 1024,
                skipNames: Set<String> = SearchRequest.defaultSkipNames) {
        self.maxDirs = maxDirs
        self.maxChildrenPerDir = maxChildrenPerDir
        self.timeBudget = timeBudget
        self.parallelism = parallelism
        self.maxResults = maxResults
        self.collectCap = collectCap
        self.skipNames = skipNames
    }

    /// Whether a directory named `name` should not be descended into.
    public func skips(_ name: String) -> Bool {
        if skipNames.contains(name) { return true }
        for pattern in skipNames where pattern.hasPrefix("*") {
            if name.hasSuffix(pattern.dropFirst()) { return true }
        }
        return false
    }
}

public struct SearchOutcome: Sendable {
    /// `search`: ranked relPaths (best first, `PathSearchEngine` order).
    /// `walk`: raw collected entries in BFS visit order.
    public let entries: [FileTreeEntry]
    public let dirsVisited: Int
    /// True when the walk ended on a budget (maxDirs / timeBudget) or the
    /// collect cap — the result is the best-so-far, not exhaustive.
    public let partial: Bool

    public init(entries: [FileTreeEntry], dirsVisited: Int, partial: Bool) {
        self.entries = entries
        self.dirsVisited = dirsVisited
        self.partial = partial
    }
}

/// Budgeted breadth-first walk over `listDirectory` — the search half of the
/// lazy-listing redesign.
///
/// The old design pre-listed the whole subtree (depth ≤ 4 / 2000 entries) so
/// matching could assume a complete index. There is no pre-listing anymore:
/// a walk reads directories on demand through `DirectoryListCache` — which
/// IS the incremental index, so directories the user already browsed are free
/// on the next search, and a new search only walks unseen directories.
/// Matching/ranking stays client-side in `PathSearchEngine`; the source only
/// serves dumb per-directory listings.
public enum TreeWalker {

    /// Kit-semantics search: collect candidates whose basename could match
    /// `query` (a sound-superset pre-filter of `PathSearchEngine.match`), then
    /// rank with the engine and return the top `maxResults` relPaths.
    public static func search(source: FilePreviewSource, root: String, query: String,
                              request: SearchRequest,
                              cache: DirectoryListCache = .shared) async throws -> SearchOutcome {
        var q = query
        while q.hasPrefix("./") { q.removeFirst(2) }
        guard !q.isEmpty, !q.hasPrefix("/"), !q.hasPrefix("~"),
              !q.split(separator: "/").contains("..") else {
            return SearchOutcome(entries: [], dirsVisited: 0, partial: false)
        }
        // The pre-filter needs the last component non-empty; the trailing
        // slash stays on `q` for match()'s named-directory semantics.
        let pre = q.hasSuffix("/") ? String(q.dropLast()) : q
        let outcome = try await walk(source: source, root: root,
                                     include: { rel, _ in candidate(rel, query: pre) },
                                     request: request, cache: cache)
        let ranked = PathSearchEngine.match(query: q, entries: outcome.entries, limit: request.maxResults)
        let isDir = Dictionary(uniqueKeysWithValues: outcome.entries.map { ($0.relPath, $0.isDir) })
        return SearchOutcome(
            entries: ranked.map { FileTreeEntry(relPath: $0, isDir: isDir[$0] ?? false) },
            dirsVisited: outcome.dirsVisited,
            partial: outcome.partial)
    }

    /// Raw walk for callers with their own ranking (the palette): every entry
    /// the `include` predicate accepts is collected, relPaths relative to
    /// `root`, budgets/caps behaving exactly like `search`.
    public static func walk(source: FilePreviewSource, root: String,
                            include: @escaping @Sendable (String, DirectoryEntry) -> Bool,
                            request: SearchRequest,
                            cache: DirectoryListCache = .shared) async throws -> SearchOutcome {
        try await _walk(source: source, root: root, include: include, request: request, cache: cache)
    }

    /// Sound-superset pre-filter for `PathSearchEngine.match`: any entry the
    /// engine could rank passes this, so the collect cap never starves a real
    /// match while memory stays bounded. Every match pass implies it: the
    /// exact component-suffix pass needs the entry's last component equal to
    /// the query's last component; the basename fragment pass needs folded
    /// equality / suffix / prefix. `q.count < 2` drops to exact equality,
    /// mirroring the engine's `q.count >= 2` fragment gate. The query's last
    /// component is what matters (the engine matches on it).
    static func candidate(_ relPath: String, query: String) -> Bool {
        guard let last = query.split(separator: "/").last else { return false }
        let q = fold(last)
        guard !q.isEmpty else { return false }
        let bn = fold((relPath as NSString).lastPathComponent)
        return bn == q || (q.count >= 2 && bn.contains(q))
    }

    private static func fold(_ s: some StringProtocol) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "")
    }

    private static func _walk(source: FilePreviewSource, root: String,
                              include: @escaping @Sendable (String, DirectoryEntry) -> Bool,
                              request: SearchRequest,
                              cache: DirectoryListCache) async throws -> SearchOutcome {
        var collected: [FileTreeEntry] = []
        var queue: [String] = [""]          // relPaths of pending dirs
        var dirsVisited = 0
        var partial = false
        let deadline = CFAbsoluteTimeGetCurrent() + request.timeBudget
        let dirRequest = DirectoryListRequest(maxChildren: request.maxChildrenPerDir)

        while !queue.isEmpty {
            guard dirsVisited < request.maxDirs,
                  CFAbsoluteTimeGetCurrent() < deadline else { partial = true; break }
            try Task.checkCancellation()
            let wave = Array(queue.prefix(request.parallelism))
            queue.removeFirst(wave.count)
            // One round trip per dir (SFTP); failing dirs are skipped — a
            // dead subdirectory must not abort the whole search.
            let listings: [(rel: String, result: DirectoryListResult?)] = await withTaskGroup(
                of: (String, DirectoryListResult?).self
            ) { group in
                for rel in wave {
                    group.addTask {
                        let dir = rel.isEmpty ? root : root + "/" + rel
                        return (rel, try? await cache.listing(source: source, path: dir, request: dirRequest))
                    }
                }
                var out: [(String, DirectoryListResult?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (rel, result) in listings {
                dirsVisited += 1
                guard let result else { continue }
                for entry in result.entries {
                    let childRel = rel.isEmpty ? entry.name : rel + "/" + entry.name
                    if include(childRel, entry) {
                        guard collected.count < request.collectCap else {
                            return SearchOutcome(entries: collected, dirsVisited: dirsVisited, partial: true)
                        }
                        collected.append(FileTreeEntry(relPath: childRel, isDir: entry.isDir))
                    }
                }
                // Symlinked dirs are isDir == false (sources report them that
                // way), so descending never follows links.
                for entry in result.entries where entry.isDir && !request.skips(entry.name) {
                    queue.append(rel.isEmpty ? entry.name : rel + "/" + entry.name)
                }
            }
        }
        return SearchOutcome(entries: collected, dirsVisited: dirsVisited, partial: partial)
    }
}
