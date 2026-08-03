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
        let source: ObjectIdentifier
        let path: String
        // Part of the key so a "show more" re-fetch with a bigger cap is not
        // served a truncated cached listing.
        let maxChildren: Int
    }

    private struct Entry {
        let result: DirectoryListResult
        let builtAt: CFAbsoluteTime
    }

    /// Injectable for tests.
    private let ttl: CFAbsoluteTime
    private let failedTTL: CFAbsoluteTime
    private let maxEntries: Int

    private var hits: [Key: Entry] = [:]
    private var order: [Key] = []            // LRU, front = oldest
    private var failed: [Key: CFAbsoluteTime] = [:]
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
            if let e = hits[key], now - e.builtAt < ttl {
                touch(key)
                return e.result
            }
            if let f = failed[key], now - f < failedTTL {
                throw FilePreviewError.unavailable("Directory listing unavailable.")
            }
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task { try await source.listDirectory(path: path, request: request) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let result = try await task.value
            hits[key] = Entry(result: result, builtAt: CFAbsoluteTimeGetCurrent())
            failed[key] = nil
            touch(key)
            return result
        } catch {
            failed[key] = CFAbsoluteTimeGetCurrent()
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
