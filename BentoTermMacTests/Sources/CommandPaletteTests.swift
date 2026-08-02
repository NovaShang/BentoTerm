import Foundation
import Testing
import BentoTerm

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
