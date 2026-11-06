import Testing
import Foundation
import CoreGraphics
@testable import BentoUISharedKit

/// The client-size bookkeeping both tiled hosts share: what's learned, what's
/// deduped, what waits for the debounce or the end of a drag.
@MainActor
@Suite("Tiled client sizer")
struct TiledClientSizerTests {

    private final class Wire {
        var pushed: [TiledClientSizer.Grid] = []
    }

    private func sizer(_ wire: Wire) -> TiledClientSizer {
        TiledClientSizer(debounce: .milliseconds(5)) { wire.pushed.append($0) }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(40))
    }

    /// iOS used to learn the cell size once, so a font change left the grid
    /// on the old cells. Every change counts; a repeat doesn't.
    @Test func learnsEveryChangeButNotARepeat() {
        let s = sizer(Wire())
        #expect(s.learn(cellWidthPx: 16, cellHeightPx: 34))
        #expect(!s.learn(cellWidthPx: 16, cellHeightPx: 34))
        #expect(s.learn(cellWidthPx: 8, cellHeightPx: 17))
        #expect(s.cellPx == CGSize(width: 8, height: 17))
        #expect(!s.learn(cellWidthPx: 0, cellHeightPx: 17))
        #expect(s.pointsPerCell(scale: 2) == CGSize(width: 4, height: 8.5))
    }

    @Test func noPointsPerCellUntilLearned() {
        #expect(sizer(Wire()).pointsPerCell(scale: 2) == nil)
    }

    /// A burst collapses into the last grid, and asking again for what tmux
    /// already has sends nothing.
    @Test func debouncesAndDedupes() async {
        let wire = Wire()
        let s = sizer(wire)
        s.request(.init(cols: 80, rows: 24))
        s.request(.init(cols: 100, rows: 30))
        await settle()
        #expect(wire.pushed == [.init(cols: 100, rows: 30)])
        s.request(.init(cols: 100, rows: 30))
        await settle()
        #expect(wire.pushed.count == 1)
    }

    @Test func runsTheFollowUpAfterThePush() async {
        let wire = Wire()
        let s = sizer(wire)
        var pushedBeforeFollowUp = -1
        s.request(.init(cols: 80, rows: 24)) { pushedBeforeFollowUp = wire.pushed.count }
        await settle()
        #expect(pushedBeforeFollowUp == 1)
    }

    /// A live window drag holds the grid; mouse-up sends the last one, once,
    /// immediately.
    @Test func holdsUntilFlushed() async {
        let wire = Wire()
        let s = sizer(wire)
        s.request(.init(cols: 90, rows: 25), holding: true)
        s.request(.init(cols: 95, rows: 26), holding: true)
        await settle()
        #expect(wire.pushed.isEmpty)
        s.flush()
        #expect(wire.pushed == [.init(cols: 95, rows: 26)])
        s.flush()
        #expect(wire.pushed.count == 1)
    }

    /// Fit Session re-asserts a size the dedupe would swallow; a font or
    /// display change forgets what was sent so it goes out again.
    @Test func pushNowAndResetBypassTheDedupe() async {
        let wire = Wire()
        let s = sizer(wire)
        s.learn(cellWidthPx: 16, cellHeightPx: 34)
        s.pushNow(.init(cols: 80, rows: 24))
        s.pushNow(.init(cols: 80, rows: 24))
        #expect(wire.pushed.count == 2)

        s.reset()
        #expect(s.cellPx == nil)
        #expect(s.lastPushed == nil)
        s.request(.init(cols: 80, rows: 24))
        await settle()
        #expect(wire.pushed.count == 3)
    }

    @Test func ignoresAnEmptyGrid() async {
        let wire = Wire()
        let s = sizer(wire)
        s.request(.init(cols: 0, rows: 24))
        await settle()
        #expect(wire.pushed.isEmpty)
        #expect(s.lastPushed == nil)
    }
}
