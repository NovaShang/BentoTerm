import XCTest
@testable import BentoFilePreviewKit

final class TreeWalkerTests: XCTestCase {

    /// The old depth cap was 4 — a file 6 levels down must still be found.
    func testSearchFindsFileDeeperThanOldDepthCap() async throws {
        let source = MockDirectorySource(dirs: [
            "/repo": .with([("a", true)]),
            "/repo/a": .with([("b", true)]),
            "/repo/a/b": .with([("c", true)]),
            "/repo/a/b/c": .with([("d", true)]),
            "/repo/a/b/c/d": .with([("e", true)]),
            "/repo/a/b/c/d/e": .with([("f.txt", false)]),
        ])
        let out = try await TreeWalker.search(source: source, root: "/repo", query: "f.txt",
                                              request: .init(maxDirs: 32, timeBudget: 30))
        XCTAssertFalse(out.partial)
        XCTAssertEqual(out.entries.map(\.relPath), ["a/b/c/d/e/f.txt"])
    }

    /// node_modules is never descended: a match inside it is invisible.
    func testSearchSkipsExactNameDirs() async throws {
        let source = MockDirectorySource(dirs: [
            "/repo": .with([("node_modules", true), ("main.txt", false)]),
            "/repo/node_modules": .with([("find-me.txt", false)]),
        ])
        let hidden = try await TreeWalker.search(source: source, root: "/repo", query: "find-me.txt",
                                                 request: .init(maxDirs: 16, timeBudget: 30))
        XCTAssertTrue(hidden.entries.isEmpty)
        let visible = try await TreeWalker.search(source: source, root: "/repo", query: "main.txt",
                                                  request: .init(maxDirs: 16, timeBudget: 30))
        XCTAssertEqual(visible.entries.map(\.relPath), ["main.txt"])
    }

    /// `*.noindex`-style suffix patterns prune too.
    func testSearchSkipsSuffixPatternDirs() async throws {
        let source = MockDirectorySource(dirs: [
            "/repo": .with([("build.noindex", true)]),
            "/repo/build.noindex": .with([("x.txt", false)]),
        ])
        let out = try await TreeWalker.search(source: source, root: "/repo", query: "x.txt",
                                              request: .init(maxDirs: 16, timeBudget: 30))
        XCTAssertTrue(out.entries.isEmpty)
    }

    /// Budget cut ⇒ partial + dirsVisited == maxDirs, deterministically.
    func testBudgetCutMarksPartial() async throws {
        let source = MockDirectorySource(dirs: [
            "/repo": .with([("a", true), ("b", true), ("c", true)]),
        ])
        let out = try await TreeWalker.search(source: source, root: "/repo", query: "f.txt",
                                              request: .init(maxDirs: 1, timeBudget: 30))
        XCTAssertTrue(out.partial)
        XCTAssertEqual(out.dirsVisited, 1)
        XCTAssertTrue(out.entries.isEmpty)
    }

    /// Per-directory child cap: only the sorted prefix is seen.
    func testSearchHonorsPerDirChildCap() async throws {
        let children = (0..<300).map { (name: String(format: "file%03d.txt", $0), isDir: false) }
        let source = MockDirectorySource(dirs: ["/repo": .with(children)])
        let out = try await TreeWalker.search(source: source, root: "/repo", query: "file299.txt",
                                              request: .init(maxDirs: 4, maxChildrenPerDir: 10, timeBudget: 30))
        XCTAssertTrue(out.entries.isEmpty)
    }

    /// A match's ancestors can be ANY name — "src/main.rs" must find
    /// pkg/src/main.rs, so the walk descends pkg even though no query
    /// component mentions it (no name-based pruning, ever).
    ///
    /// Both matches are expected, in the source's sort order ("other" before
    /// "pkg") rather than the order they are written below.
    func testSearchFindsSuffixMatchAcrossArbitraryAncestors() async throws {
        let source = MockDirectorySource(dirs: [
            "/repo": .with([("pkg", true), ("other", true)]),
            "/repo/pkg": .with([("src", true)]),
            "/repo/pkg/src": .with([("main.rs", false), ("unrelated.py", false)]),
            "/repo/other": .with([("src", true)]),
            "/repo/other/src": .with([("main.rs", false)]),
        ])
        let out = try await TreeWalker.search(source: source, root: "/repo", query: "src/main.rs",
                                              request: .init(maxDirs: 32, timeBudget: 30))
        XCTAssertEqual(out.entries.map(\.relPath), ["other/src/main.rs", "pkg/src/main.rs"])
    }

    /// Fragment query (a wrap-eaten name half) still finds via the engine's
    /// basename fragment pass.
    func testFragmentQueryFindsWrappedName() async throws {
        let source = MockDirectorySource(dirs: [
            "/repo": .with([("src", true)]),
            "/repo/src": .with([("main.rs", false)]),
        ])
        let out = try await TreeWalker.search(source: source, root: "/repo", query: "ain.rs",
                                              request: .init(maxDirs: 8, timeBudget: 30))
        XCTAssertEqual(out.entries.map(\.relPath), ["src/main.rs"])
    }

    /// Trailing slash = directory query, resolved through the engine's
    /// named-directory semantics.
    func testDirQueryWithTrailingSlash() async throws {
        let source = MockDirectorySource(dirs: [
            "/repo": .with([("Sources", true)]),
        ])
        let out = try await TreeWalker.search(source: source, root: "/repo", query: "Sources/",
                                              request: .init(maxDirs: 4, timeBudget: 30))
        XCTAssertEqual(out.entries.map(\.relPath), ["Sources"])
    }

    /// Collect cap hit ⇒ partial, walk stops (the deep dir never listed).
    func testCollectCapMarksPartialAndStopsWalking() async throws {
        let root = (0..<30).map { (name: "m0-\($0).txt", isDir: false) }
        let source = MockDirectorySource(dirs: [
            "/repo": .with(root + [("deep", true)]),
            "/repo/deep": .with([("m0-special.txt", false)]),
        ])
        let out = try await TreeWalker.search(source: source, root: "/repo", query: "m0-",
                                              request: .init(maxDirs: 8, timeBudget: 30, collectCap: 10))
        XCTAssertTrue(out.partial)
        XCTAssertEqual(out.entries.count, 10)
        let calls = await source.listDirCalls
        XCTAssertEqual(calls, 1)   // walk stopped before descending into deep
    }

    /// A cancellation before the first wave surfaces as CancellationError.
    func testCancelledSearchThrows() async throws {
        let source = MockDirectorySource(dirs: [
            "/repo": .with([("a.txt", false)]),
        ])
        let task = Task {
            try await TreeWalker.search(source: source, root: "/repo", query: "a.txt",
                                        request: .init(maxDirs: 8, timeBudget: 30))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        }
    }

    /// `walk` collects whatever the predicate accepts, relPaths relative to
    /// root, dirsVisited counting attempted dirs.
    func testWalkCollectsPredicateMatches() async throws {
        let source = MockDirectorySource(dirs: [
            "/repo": .with([("a.txt", false), ("sub", true), ("b.md", false)]),
            "/repo/sub": .with([("c.txt", false)]),
        ])
        let out = try await TreeWalker.walk(source: source, root: "/repo", include: { rel, _ in
            rel.hasSuffix(".txt")
        }, request: .init(maxDirs: 8, timeBudget: 30))
        XCTAssertEqual(Set(out.entries.map(\.relPath)), ["a.txt", "sub/c.txt"])
        XCTAssertEqual(out.dirsVisited, 2)
    }
}
