import Foundation

/// One directory listing per (source, path, maxChildren) — the lazy
/// incremental index shared by browse, tap search, and the palette. A
/// directory listed once (by a browse expansion, a search walk, or the
/// palette) is served from cache for every later consumer, so a search only
/// walks directories it hasn't seen. Nothing here knows about trees or
/// budgets — it's a dumb per-directory cache with in-flight dedup.
public actor DirectoryListCache {
    public static let shared = DirectoryListCache()

    private struct Key: Hashable {
        /// The source's ADDRESS, which is only unique among LIVE objects — see
        /// `Entry.source` for why every hit is confirmed against the object
        /// itself before it is served.
        let source: ObjectIdentifier
        let path: String
        // Part of the key so a "show more" re-fetch with a bigger cap is not
        // served a truncated cached listing.
        let maxChildren: Int
    }

    private struct Entry {
        let result: DirectoryListResult
        let builtAt: CFAbsoluteTime
        /// The source these listings came from, held WEAKLY.
        ///
        /// `ObjectIdentifier` is an address, and the cache keeps no strong
        /// reference — so once a source is deallocated, the next source
        /// allocated can land on the same address and inherit the dead one's
        /// entries wholesale. That is not hypothetical: sources are per
        /// connection, and a reconnect frees one and builds another in the same
        /// breath, which is exactly the allocation pattern that reuses an
        /// address. The visible bug is path preview listing the PREVIOUS host's
        /// directories for the TTL after a reconnect.
        ///
        /// Confirming identity here makes the reuse harmless: a dead source
        /// leaves a nil, which reads as a miss.
        weak var source: (any FilePreviewSource)?
    }

    private struct FailedEntry {
        let at: CFAbsoluteTime
        weak var source: (any FilePreviewSource)?
    }

    /// Injectable for tests.
    private let ttl: CFAbsoluteTime
    private let failedTTL: CFAbsoluteTime
    private let maxEntries: Int

    private var hits: [Key: Entry] = [:]
    private var order: [Key] = []            // LRU, front = oldest
    private var failed: [Key: FailedEntry] = [:]
    private var inFlight: [Key: Task<DirectoryListResult, Error>] = [:]

    public init() {
        self.init(ttl: 30, failedTTL: 30, maxEntries: 256)
    }

    public init(ttl: CFAbsoluteTime, failedTTL: CFAbsoluteTime, maxEntries: Int) {
        self.ttl = ttl
        self.failedTTL = failedTTL
        self.maxEntries = maxEntries
    }

    /// One directory's listing. `refresh: true` bypasses TTL and negative
    /// cache (the browser's reload button) but still dedups in-flight calls.
    public func listing(source: FilePreviewSource, path: String,
                        request: DirectoryListRequest,
                        refresh: Bool = false) async throws -> DirectoryListResult {
        let key = Key(source: ObjectIdentifier(source), path: path, maxChildren: request.maxChildren)
        let now = CFAbsoluteTimeGetCurrent()
        if !refresh {
            if let e = hits[key], now - e.builtAt < ttl, e.source === source {
                touch(key)
                return e.result
            }
            if let f = failed[key], now - f.at < failedTTL, f.source === source {
                throw FilePreviewError.unavailable("Directory listing unavailable.")
            }
        }
        // In-flight needs no identity check: a task can only be in flight while
        // its source is alive, and a live object's address is not reusable.
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task { try await source.listDirectory(path: path, request: request) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let result = try await task.value
            hits[key] = Entry(result: result, builtAt: CFAbsoluteTimeGetCurrent(), source: source)
            failed[key] = nil
            touch(key)
            return result
        } catch {
            failed[key] = FailedEntry(at: CFAbsoluteTimeGetCurrent(), source: source)
            touch(key)          // failed entries are LRU-tracked too (eviction)
            throw error
        }
    }

    private func touch(_ key: Key) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
        while order.count > maxEntries {
            let evict = order.removeFirst()
            hits[evict] = nil
            failed[evict] = nil
        }
    }
}
