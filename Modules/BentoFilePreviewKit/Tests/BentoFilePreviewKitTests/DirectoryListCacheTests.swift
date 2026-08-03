import XCTest
@testable import BentoFilePreviewKit

final class DirectoryListCacheTests: XCTestCase {

    func testHitServedWithoutSourceCall() async throws {
        let source = MockDirectorySource(dirs: ["/repo": .with([("a.txt", false)])])
        let cache = DirectoryListCache(ttl: 60, failedTTL: 60, maxEntries: 8)
        _ = try await cache.listing(source: source, path: "/repo", request: .init())
        _ = try await cache.listing(source: source, path: "/repo", request: .init())
        let calls = await source.listDirCalls
        XCTAssertEqual(calls, 1)
    }

    func testTTLExpiryRefetches() async throws {
        let source = MockDirectorySource(dirs: ["/repo": .with([("a.txt", false)])])
        let cache = DirectoryListCache(ttl: 0.05, failedTTL: 60, maxEntries: 8)
        _ = try await cache.listing(source: source, path: "/repo", request: .init())
        try await Task.sleep(for: .milliseconds(80))
        _ = try await cache.listing(source: source, path: "/repo", request: .init())
        let calls = await source.listDirCalls
        XCTAssertEqual(calls, 2)
    }

    func testConcurrentCallersDedupeInFlight() async throws {
        let source = MockDirectorySource(dirs: ["/repo": .with([("a.txt", false)])])
        let cache = DirectoryListCache(ttl: 60, failedTTL: 60, maxEntries: 8)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try await cache.listing(source: source, path: "/repo", request: .init()) }
            }
            try await group.waitForAll()
        }
        let calls = await source.listDirCalls
        XCTAssertEqual(calls, 1)
    }

    func testNegativeCacheServesFailureWithoutSourceCall() async throws {
        let source = MockDirectorySource(dirs: [:], failDirs: ["/repo"])
        let cache = DirectoryListCache(ttl: 60, failedTTL: 60, maxEntries: 8)
        do { _ = try await cache.listing(source: source, path: "/repo", request: .init()) }
        catch { /* expected */ }
        do {
            _ = try await cache.listing(source: source, path: "/repo", request: .init())
            XCTFail("expected throw from the negative cache")
        } catch {}
        let calls = await source.listDirCalls
        XCTAssertEqual(calls, 1)
    }

    /// A "show more" re-fetch with a bigger cap must not be served the
    /// truncated cached listing — maxChildren is part of the key.
    func testMaxChildrenIsPartOfTheKey() async throws {
        let source = MockDirectorySource(handler: { _, maxChildren in
            maxChildren >= 100
                ? DirectoryListResult(entries: (0..<300).map { DirectoryEntry(name: "f\($0).txt", isDir: false) },
                                      truncated: true)
                : DirectoryListResult(entries: [DirectoryEntry(name: "a.txt", isDir: false)], truncated: false)
        })
        let cache = DirectoryListCache(ttl: 60, failedTTL: 60, maxEntries: 8)
        let small = try await cache.listing(source: source, path: "/repo", request: .init(maxChildren: 10))
        XCTAssertEqual(small.entries.count, 1)
        XCTAssertFalse(small.truncated)
        let big = try await cache.listing(source: source, path: "/repo", request: .init(maxChildren: 300))
        XCTAssertEqual(big.entries.count, 300)
        XCTAssertTrue(big.truncated)
        let calls = await source.listDirCalls
        XCTAssertEqual(calls, 2)
    }

    func testRefreshBypassesCache() async throws {
        let source = MockDirectorySource(dirs: ["/repo": .with([("a.txt", false)])])
        let cache = DirectoryListCache(ttl: 60, failedTTL: 60, maxEntries: 8)
        _ = try await cache.listing(source: source, path: "/repo", request: .init())
        _ = try await cache.listing(source: source, path: "/repo", request: .init(), refresh: true)
        let calls = await source.listDirCalls
        XCTAssertEqual(calls, 2)
    }

    func testLRUEvictsOldest() async throws {
        let source = MockDirectorySource(dirs: [
            "/a": .with([("1.txt", false)]),
            "/b": .with([("2.txt", false)]),
            "/c": .with([("3.txt", false)]),
        ])
        let cache = DirectoryListCache(ttl: 60, failedTTL: 60, maxEntries: 2)
        _ = try await cache.listing(source: source, path: "/a", request: .init())
        _ = try await cache.listing(source: source, path: "/b", request: .init())
        _ = try await cache.listing(source: source, path: "/c", request: .init())   // evicts /a
        _ = try await cache.listing(source: source, path: "/a", request: .init())   // refetch
        let calls = await source.listDirCalls
        XCTAssertEqual(calls, 4)
    }
}
