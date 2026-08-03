import Foundation
import SwiftUI

/// Expansion state for the lazy file-tree browser — one store per browser
/// instance (each iOS sheet / dock tab owns one).
///
/// Everything here is gesture-driven UI state (@MainActor). Every fetch
/// happens inside `DirectoryListCache` (a nonisolated actor) — which is ALSO
/// the incremental index behind tap search and the palette — so a directory
/// you expand is free for the next search, and vice versa. Depth is
/// unlimited; the only cap left is per-directory (`maxChildren`, with a
/// "show more" ladder).
@MainActor
public final class LazyDirectoryTreeStore: ObservableObject {
    /// One directory's browse state, keyed by relPath ("" = root).
    public struct DirState: Equatable {
        public var entries: [DirectoryEntry]? = nil   // nil = not loaded yet
        public var loading = false
        public var error: String?
        public var truncated = false
        public var maxChildren = 200
        public var expanded = false

        public init() {}
    }

    @Published public private(set) var root: String?
    @Published public private(set) var rootError: String?
    @Published public private(set) var rootLoading = false
    @Published private var dirs: [String: DirState] = [:]

    private var context: PathPreviewContext?
    private var tasks: [String: Task<Void, Never>] = [:]
    private let cache: DirectoryListCache

    /// Ladder for the "show more" row — each step re-fetches with a bigger
    /// per-directory cap (the cache keys on maxChildren, so it really
    /// re-fetches). Past the top the row turns into an inert "Too many items".
    private static let ladder = [200, 600, 1500, 4000]

    public init(cache: DirectoryListCache = .shared) {
        self.cache = cache
    }

    // MARK: State access

    public func state(of dir: String) -> DirState {
        dirs[dir] ?? DirState()
    }

    // MARK: Gestures

    /// Expand (fetch children on first expand) / collapse. A collapse mid-
    /// fetch keeps the in-flight result: it lands in state, the row is gone,
    /// and re-expanding serves it from state/cache instantly.
    public func toggle(_ dir: String) {
        var st = state(of: dir)
        if st.expanded {
            st.expanded = false
            dirs[dir] = st
            return
        }
        st.expanded = true
        dirs[dir] = st
        if st.entries == nil { fetch(dir) }
    }

    /// Re-fetch with the next `maxChildren` step. At the ladder top the row
    /// is already inert ("Too many items"), so this is a no-op.
    public func showMore(_ dir: String) {
        var st = state(of: dir)
        guard let next = Self.ladder.first(where: { $0 > st.maxChildren }) else { return }
        st.maxChildren = next
        st.expanded = true
        dirs[dir] = st
        fetch(dir)
    }

    /// Re-fetch a failed directory, bypassing the negative cache.
    public func retry(_ dir: String) {
        fetch(dir, refresh: true)
    }

    /// Re-fetch the root listing (the browser's reload button). Expansion is
    /// preserved — only the root's contents refresh.
    public func reload() {
        fetch("", refresh: true)
    }

    /// Point the store at a new (pane, root). Clears all expansion and
    /// cancels in-flight fetches, then lists the root.
    public func reset(context: PathPreviewContext, root: String) {
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
        dirs.removeAll()
        self.context = context
        self.root = root
        rootError = nil
        rootLoading = true
        fetch("")
    }

    /// Failure surface for the browser's pre-flight guards (no active pane,
    /// remote shell we can't reach, unknown cwd) — the root error view owns
    /// all failure text.
    public func resetFailed(_ message: String) {
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
        dirs.removeAll()
        context = nil
        root = nil
        rootError = message
        rootLoading = false
    }

    // MARK: Fetching

    private func fetch(_ dir: String, refresh: Bool = false) {
        guard let ctx = context, let root else { return }
        var st = state(of: dir)
        guard refresh || !st.loading else { return }
        st.loading = true
        st.error = nil
        dirs[dir] = st
        let abs = dir.isEmpty ? root : root + "/" + dir
        let maxChildren = st.maxChildren
        let task = Task { [weak self] in
            let result: DirectoryListResult?
            var err: String?
            do {
                result = try await cache.listing(source: ctx.source, path: abs,
                                                 request: DirectoryListRequest(maxChildren: maxChildren),
                                                 refresh: refresh)
            } catch {
                result = nil
                err = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            self?.apply(result, error: err, to: dir)
        }
        tasks[dir] = task
    }

    private func apply(_ result: DirectoryListResult?, error: String?, to dir: String) {
        var st = state(of: dir)
        st.loading = false
        st.error = error
        if let result {
            st.entries = result.entries
            st.truncated = result.truncated
        }
        dirs[dir] = st
        if dir.isEmpty { rootLoading = false }
    }
}
