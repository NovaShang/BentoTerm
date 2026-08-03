import Foundation
import Testing
import BentoTerm
import BentoUISharedKit
import BentoFilePreviewKit

// MARK: - Fuzzy scorer

@Suite struct PaletteFuzzyTests {
    @Test func nonSubsequenceIsNil() {
        #expect(PaletteFuzzy.score(query: "xyz", target: "PaneViewModel") == nil)
        #expect(PaletteFuzzy.score(query: "zzz", target: "readme") == nil)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(PaletteFuzzy.score(query: "", target: "anything") == 0)
        #expect(PaletteFuzzy.score(query: "   ", target: "anything") == 0)
    }

    @Test func subsequenceMatches() {
        #expect(PaletteFuzzy.score(query: "pvm", target: "PaneViewModel") != nil)
        #expect(PaletteFuzzy.score(query: "readme", target: "README.md") != nil)
    }

    @Test func spacesInQueryAreIgnored() {
        // "pane view" must find "PaneViewModel" — the command-box promise.
        #expect(PaletteFuzzy.score(query: "pane view", target: "PaneViewModel.swift") != nil)
    }

    @Test func wordBoundariesAndCamelHumpsRankHigher() {
        // "pv" hits P (start) + V (camel hump) in PaneViewModel — worth far more
        // than the same letters buried mid-word in "improve".
        let strong = PaletteFuzzy.score(query: "pv", target: "PaneViewModel")!
        let weak = PaletteFuzzy.score(query: "pv", target: "improve")!
        #expect(strong > weak)
    }

    @Test func caseInsensitive() {
        #expect(PaletteFuzzy.score(query: "PVM", target: "paneviewmodel") != nil)
        #expect(PaletteFuzzy.score(query: "pane", target: "PANE.md") != nil)
    }

    // MARK: rank()

    private func items(_ titles: [String]) -> [PaletteItem] {
        titles.map { PaletteItem(id: $0, title: $0, systemImage: "doc", action: .run {}) }
    }

    @Test func rankOrdersByRelevance() {
        let ranked = PaletteFuzzy.rank(
            query: "read",
            items: items(["thread.c", "README.md", "zzz.bin"]),
            limit: 10)
        #expect(ranked.first?.title == "README.md")   // consecutive-from-start wins
        #expect(!ranked.contains { $0.title == "zzz.bin" })  // genuine non-match dropped
    }

    @Test func rankEmptyQueryPreservesOrderAndCaps() {
        let ranked = PaletteFuzzy.rank(query: "", items: items(["a", "b", "c"]), limit: 2)
        #expect(ranked.map(\.title) == ["a", "b"])
    }
}

// MARK: - Static section spec

@Suite struct PaletteSectionSpecTests {
    private func item(_ t: String) -> PaletteItem {
        PaletteItem(id: t, title: t, systemImage: "doc", action: .run {})
    }

    @Test func emptyStateOnlyHidesWhileTyping() {
        let spec = PaletteSectionSpec(id: "recent", title: "Recent",
                                      items: [item("README.md")], emptyStateOnly: true)
        #expect(spec.resolved(query: "")?.items.count == 1)   // shown when idle
        #expect(spec.resolved(query: "read") == nil)          // hidden once typing
    }

    @Test func regularSectionFiltersWhileTyping() {
        let spec = PaletteSectionSpec(id: "cmds", title: "Commands",
                                      items: [item("Split Pane"), item("Close Pane")])
        #expect(spec.resolved(query: "")?.items.count == 2)
        let split = spec.resolved(query: "split")
        #expect(split?.items.map(\.title) == ["Split Pane"])
    }

    @Test func noMatchesDropsSection() {
        let spec = PaletteSectionSpec(id: "cmds", title: "Commands", items: [item("Zoom")])
        #expect(spec.resolved(query: "xyzzy") == nil)
    }
}

// MARK: - File browser (lazy walk over per-directory listings)

/// Minimal in-memory source for palette file-browser tests.
private actor PaletteMockSource: FilePreviewSource {
    var dirs: [String: DirectoryListResult]
    private(set) var listDirCalls = 0

    init(dirs: [String: DirectoryListResult]) { self.dirs = dirs }

    func stat(path: String, cwd: String?) async throws -> (resolvedPath: String, stat: FilePreviewStat) {
        throw FilePreviewError.unavailable("stat is not used in palette browser tests")
    }

    func read(resolvedPath: String, maxBytes: Int) async throws -> Data { Data() }

    func listDirectory(path: String, request: DirectoryListRequest) async throws -> DirectoryListResult {
        listDirCalls += 1
        guard let d = dirs[path] else { throw FilePreviewError.notFound(path) }
        return d
    }
}

@Suite struct PaletteFileBrowserTests {
    private func context(_ source: FilePreviewSource, root: String) -> PathPreviewContext {
        PathPreviewContext(source: source, cwd: { root }, hostLabel: "test", isLocal: true)
    }

    @Test func emptyQueryReturnsImmediateChildrenDirsFirst() async {
        let src = PaletteMockSource(dirs: [
            "/palette-empty": DirectoryListResult(entries: [
                DirectoryEntry(name: "z-file.txt", isDir: false),
                DirectoryEntry(name: "a-dir", isDir: true),
                DirectoryEntry(name: "b.txt", isDir: false),
            ], truncated: false),
        ])
        let r = await PaletteFileBrowser.items(query: "", root: "/palette-empty", context: context(src, root: "/palette-empty"))
        // Directories first, then alphabetical — no whole-tree listing.
        #expect(r.items.map(\.title) == ["a-dir/", "b.txt", "z-file.txt"])
        let calls = await src.listDirCalls
        #expect(calls == 1)
    }

    @Test func typedQueryFuzzyRanksWalkResults() async {
        let src = PaletteMockSource(dirs: [
            "/palette-typed": DirectoryListResult(entries: [
                DirectoryEntry(name: "Sources", isDir: true),
                DirectoryEntry(name: "README.md", isDir: false),
            ], truncated: false),
            "/palette-typed/Sources": DirectoryListResult(entries: [
                DirectoryEntry(name: "MainView.swift", isDir: false),
                DirectoryEntry(name: "Unrelated.swift", isDir: false),
            ], truncated: false),
        ])
        let r = await PaletteFileBrowser.items(query: "mainv", root: "/palette-typed", context: context(src, root: "/palette-typed"))
        #expect(r.items.map(\.title) == ["MainView.swift"])
        #expect(!r.partial)
        // The subtree walk visited root + Sources.
        #expect(r.dirsSearched == 2)
    }

    @Test func emptyResultCompletesWithoutPartial() async {
        let src = PaletteMockSource(dirs: [
            "/palette-miss": DirectoryListResult(entries: [
                DirectoryEntry(name: "a", isDir: true),
                DirectoryEntry(name: "b", isDir: true),
                DirectoryEntry(name: "c", isDir: true),
            ], truncated: false),
        ])
        let r = await PaletteFileBrowser.items(query: "needle", root: "/palette-miss", context: context(src, root: "/palette-miss"))
        #expect(r.items.isEmpty)
        #expect(!r.partial)
        // The walk runs to the end of the queue: root + a + b + c.
        #expect(r.dirsSearched == 4)
    }
}
