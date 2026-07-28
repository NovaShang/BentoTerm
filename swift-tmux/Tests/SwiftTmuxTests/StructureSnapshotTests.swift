import Testing
@testable import SwiftTmux

@Suite("structure snapshot")
struct StructureSnapshotTests {

    private func pane(_ n: Int) -> TmuxPaneID { TmuxPaneID(n) }

    private var mixed: TmuxStructureSnapshot {
        // 3 windows, the middle one holding two panes — the ordinary tmux shape
        // that the old single-layout memory could not describe at all.
        TmuxStructureSnapshot(windows: [
            .init(index: 0, name: "editor", layout: "b25d,80x24,0,0,1", panes: [pane(1)]),
            .init(index: 1, name: "server",
                  layout: "6b1f,120x40,0,0{60x40,0,0,2,59x40,61,0,3}",
                  panes: [pane(2), pane(3)]),
            .init(index: 2, name: "logs", layout: "a11e,80x24,0,0,4", panes: [pane(4)]),
        ])
    }

    // MARK: Storage

    @Test func roundTripsThroughStorage() {
        let encoded = mixed.encoded()
        #expect(encoded != nil)
        #expect(TmuxStructureSnapshot.decode(encoded) == mixed)
    }

    /// The stored form must not contain anything tmux's command lexer treats as
    /// syntax. A layout string carries braces, and an unquoted brace once made
    /// the whole `set-option` fail with a silent syntax error (114ef43).
    @Test func storedFormIsInertToTmuxLexer() throws {
        let encoded = try #require(mixed.encoded())
        let hazards: Set<Character> = ["{", "}", ";", "#", "'", "\"", "\\", " ", "[", "]"]
        #expect(!encoded.contains(where: { hazards.contains($0) }),
                "stored snapshot must be base64-clean; got: \(encoded)")
    }

    @Test func decodeRejectsGarbageInsteadOfCrashing() {
        #expect(TmuxStructureSnapshot.decode(nil) == nil)
        #expect(TmuxStructureSnapshot.decode("") == nil)
        #expect(TmuxStructureSnapshot.decode("not base64 at all !!") == nil)
        // Valid base64, wrong payload.
        #expect(TmuxStructureSnapshot.decode("aGVsbG8=") == nil)
    }

    @Test func windowNameWithLexerHazardsSurvives() throws {
        let snap = TmuxStructureSnapshot(windows: [
            .init(index: 0, name: "it's #{weird}; \"really\"", layout: nil, panes: [pane(1)]),
        ])
        let encoded = try #require(snap.encoded())
        #expect(TmuxStructureSnapshot.decode(encoded) == snap)
    }

    // MARK: Restore planning

    @Test func planRebuildsEveryWindowNotJustOne() {
        let plan = mixed.restorePlan(livePanes: [pane(1), pane(2), pane(3), pane(4)])
        #expect(plan.count == 3)
        #expect(plan.map(\.base) == [pane(1), pane(2), pane(4)])
        #expect(plan.map(\.join) == [[], [pane(3)], []])
        #expect(plan.map(\.name) == ["editor", "server", "logs"])
    }

    /// Join order IS the geometry mapping: `select-layout` fills the saved
    /// layout's slots by window order and ignores the pane ids inside the
    /// string, so a reordered join puts every pane in the wrong cell.
    @Test func joinOrderFollowsCaptureOrder() {
        let snap = TmuxStructureSnapshot(windows: [
            .init(index: 0, name: "w", layout: "L", panes: [pane(7), pane(3), pane(9)]),
        ])
        let plan = snap.restorePlan(livePanes: [pane(3), pane(7), pane(9)])
        #expect(plan.first?.base == pane(7))
        #expect(plan.first?.join == [pane(3), pane(9)])
    }

    @Test func deadPanesDropOutAndTheirWindowDisappears() {
        let plan = mixed.restorePlan(livePanes: [pane(1), pane(3)])
        #expect(plan.count == 2)
        // Window "server" lost pane 2, so surviving pane 3 becomes the base.
        #expect(plan.map(\.base) == [pane(1), pane(3)])
        // Window "logs" had only pane 4, which is gone — no step at all.
        #expect(!plan.contains { $0.name == "logs" })
    }

    /// A layout string encodes an exact pane count. If a pane died the geometry
    /// no longer fits, so the plan drops it and the caller falls back to tmux's
    /// even layout rather than applying something tmux will reject.
    @Test func partialSurvivalDropsTheSavedLayout() {
        let plan = mixed.restorePlan(livePanes: [pane(1), pane(3), pane(4)])
        let server = plan.first { $0.name == "server" }
        #expect(server?.layout == nil)
        // Untouched windows keep theirs.
        #expect(plan.first { $0.name == "editor" }?.layout == "b25d,80x24,0,0,1")
    }

    /// Panes created while rearranged are not in the snapshot; they must be
    /// left where they are, never yanked into an arbitrary window.
    @Test func unknownPanesAreNotPlanned() {
        let plan = mixed.restorePlan(livePanes: [pane(1), pane(2), pane(3), pane(4), pane(99)])
        #expect(!plan.contains { $0.base == pane(99) || $0.join.contains(pane(99)) })
    }

    @Test func emptySurvivalYieldsEmptyPlan() {
        #expect(mixed.restorePlan(livePanes: []).isEmpty)
    }

    @Test func allPanesIsWindowThenPaneOrder() {
        #expect(mixed.allPanes == [pane(1), pane(2), pane(3), pane(4)])
    }
}
