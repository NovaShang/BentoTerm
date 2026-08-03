import XCTest
@testable import BentoFilePreviewKit

@MainActor
final class LazyDirectoryTreeStoreTests: XCTestCase {

    private func context(_ source: FilePreviewSource) -> PathPreviewContext {
        PathPreviewContext(source: source, cwd: { "/repo" }, hostLabel: "test", isLocal: true)
    }

    private func waitUntil(_ cond: () -> Bool) async {
        var tries = 0
        while !cond(), tries < 200 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testToggleFetchesOnce() async throws {
        let src = MockDirectorySource(dirs: [
            "/repo": .with([("a", true), ("f.txt", false)]),
            "/repo/a": .with([("inner.txt", false)]),
        ])
        let store = LazyDirectoryTreeStore(cache: DirectoryListCache(ttl: 60, failedTTL: 60, maxEntries: 8))
        store.reset(context: context(src), root: "/repo")
        await waitUntil { store.state(of: "").entries != nil }
        XCTAssertEqual(store.state(of: "").entries?.count, 2)

        store.toggle("a")
        await waitUntil { store.state(of: "a").entries != nil }
        XCTAssertEqual(store.state(of: "a").entries?.map(\.name), ["inner.txt"])
        XCTAssertTrue(store.state(of: "a").expanded)

        store.toggle("a")   // collapse
        XCTAssertFalse(store.state(of: "a").expanded)
        store.toggle("a")   // re-expand — served from state, no refetch
        let calls = await src.listDirCalls
        XCTAssertEqual(calls, 2)   // root + a only
    }

    func testFailedDirShowsErrorAndRetryRecovers() async throws {
        let src = MockDirectorySource(dirs: [
            "/repo": .with([("bad", true)]),
            "/repo/bad": .with([("x.txt", false)]),
        ], failDirs: ["/repo/bad"])
        let store = LazyDirectoryTreeStore(cache: DirectoryListCache(ttl: 60, failedTTL: 60, maxEntries: 8))
        store.reset(context: context(src), root: "/repo")
        await waitUntil { store.state(of: "").entries != nil }

        store.toggle("bad")
        await waitUntil { store.state(of: "bad").error != nil }
        XCTAssertNil(store.state(of: "bad").entries)

        await src.unfail("/repo/bad")
        store.retry("bad")
        await waitUntil { store.state(of: "bad").entries != nil }
        XCTAssertEqual(store.state(of: "bad").entries?.map(\.name), ["x.txt"])
        XCTAssertNil(store.state(of: "bad").error)
    }

    func testShowMoreLadderRefetchesWithBiggerCap() async throws {
        let src = MockDirectorySource(handler: { _, maxChildren in
            maxChildren >= 600
                ? DirectoryListResult(entries: (0..<800).map { DirectoryEntry(name: "f\($0).txt", isDir: false) },
                                      truncated: true)
                : DirectoryListResult(entries: (0..<300).map { DirectoryEntry(name: "f\($0).txt", isDir: false) },
                                      truncated: true)
        })
        let store = LazyDirectoryTreeStore(cache: DirectoryListCache(ttl: 60, failedTTL: 60, maxEntries: 8))
        store.reset(context: context(src), root: "/repo")
        await waitUntil { store.state(of: "").entries != nil }
        XCTAssertEqual(store.state(of: "").entries?.count, 200)   // capped at the default
        XCTAssertTrue(store.state(of: "").truncated)

        store.showMore("")
        await waitUntil { store.state(of: "").entries?.count == 600 }
        XCTAssertEqual(store.state(of: "").maxChildren, 600)
    }

    func testResetClearsState() async throws {
        let src = MockDirectorySource(dirs: [
            "/repo": .with([("a", true)]),
            "/repo/a": .with([("inner.txt", false)]),
            "/other": .with([("b.txt", false)]),
        ])
        let store = LazyDirectoryTreeStore(cache: DirectoryListCache(ttl: 60, failedTTL: 60, maxEntries: 8))
        store.reset(context: context(src), root: "/repo")
        await waitUntil { store.state(of: "").entries != nil }
        store.toggle("a")
        await waitUntil { store.state(of: "a").entries != nil }

        store.reset(context: context(src), root: "/other")
        await waitUntil { store.state(of: "").entries?.map(\.name) == ["b.txt"] }
        XCTAssertNil(store.state(of: "a").entries)   // old expansion gone
    }

    func testReloadRefreshesRootBypassingCache() async throws {
        let src = MockDirectorySource(dirs: ["/repo": .with([("a.txt", false)])])
        let store = LazyDirectoryTreeStore(cache: DirectoryListCache(ttl: 60, failedTTL: 60, maxEntries: 8))
        store.reset(context: context(src), root: "/repo")
        await waitUntil { store.state(of: "").entries != nil }
        store.reload()
        await waitUntil { !store.state(of: "").loading }
        let calls = await src.listDirCalls
        XCTAssertEqual(calls, 2)   // reset's root listing + the refresh
    }
}
