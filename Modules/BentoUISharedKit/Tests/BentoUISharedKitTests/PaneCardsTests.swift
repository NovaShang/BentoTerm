import Testing
import CoreGraphics
import BentoTmuxKit
@testable import BentoUISharedKit

struct PaneCardsTests {
    private let cell = CGSize(width: 8, height: 17)
    private var m: PaneCardMetrics { .mac(cell: cell) }

    private func panes(_ layout: String) -> [Pane] {
        TmuxParsers.parsePaneGeometry(layout).map {
            Pane(id: $0.id, width: $0.width, height: $0.height, x: $0.x, y: $0.y,
                 isActive: false, currentCommand: nil, title: nil)
        }
    }

    // Two over one; a 2-vs-3 stack; a 2×2.
    private let layouts = [
        "207f,196x59,0,0[196x28,0,0{98x28,0,0,0,97x28,99,0,2},196x30,0,29,1]",
        "abcd,100x50,0,0{50x50,0,0[50x24,0,0,1,50x25,0,25,2],49x50,51,0[49x16,51,0,3,49x16,51,17,4,49x16,51,34,5]}",
        "abcd,81x41,0,0{40x41,0,0[40x20,0,0,1,40x20,0,21,2],40x41,41,0[40x20,41,0,3,40x20,41,21,4]}",
    ]

    private func viewport(for tree: TmuxLayoutTree.Node, cols: Int, rows: Int) -> CGSize {
        let c = PaneCards.chrome(tree, cell: cell, metrics: m)
        return CGSize(width: CGFloat(cols) * cell.width + c.width + 2 * m.margin + 3,
                      height: CGFloat(rows) * cell.height + c.height + 2 * m.margin + 5)
    }

    @Test func surfacesAreCellExactAndCardsNeverOverlapOrOverflow() throws {
        for layout in layouts {
            let ps = panes(layout)
            let tree = try #require(PaneCards.tree(layouts: [layout], panes: ps))
            let grid = PaneTiling.gridSize(panes: ps)
            let vp = viewport(for: tree, cols: Int(grid.cols), rows: Int(grid.rows))
            let cards = PaneCards.cards(tree: tree, viewport: vp, cell: cell, scale: 2, metrics: m)
            #expect(cards.count == ps.count)
            for p in ps {
                let card = try #require(cards[p.id])
                #expect(card.surfaceFrame.width == CGFloat(p.width) * cell.width)
                #expect(card.surfaceFrame.height == CGFloat(p.height) * cell.height)
                // The surface keeps its padding inside the card.
                #expect(card.surfaceFrame.minX - card.frame.minX >= m.padding)
                #expect(card.frame.maxX - card.surfaceFrame.maxX >= m.padding)
                #expect(card.frame.maxY - card.surfaceFrame.maxY >= m.bottomPadding)
                #expect(card.frame.maxX <= vp.width - m.margin + 0.001)
                #expect(card.frame.maxY <= vp.height - m.margin + 0.001)
                for (id, other) in cards where id != p.id {
                    #expect(!card.frame.insetBy(dx: -m.gap / 2 + 0.01, dy: -m.gap / 2 + 0.01)
                        .intersects(other.frame.insetBy(dx: -m.gap / 2 + 0.01, dy: -m.gap / 2 + 0.01)))
                }
            }
            // The margin is the gap, on all four sides.
            #expect(m.margin == m.gap)
            #expect(cards.values.map(\.frame.minX).min() == m.gap)
            #expect(cards.values.map(\.frame.minY).min() == m.gap)
            #expect(cards.values.map(\.frame.maxX).max() == vp.width - m.gap)
            #expect(cards.values.map(\.frame.maxY).max() == vp.height - m.gap)
        }
    }

    /// The pushed size depends on structure only: laying out the answer asks
    /// for the same answer again.
    @Test func clientGridIsAFixedPoint() throws {
        for layout in layouts {
            let ps = panes(layout)
            let tree = try #require(PaneCards.tree(layouts: [layout], panes: ps))
            let grid = PaneTiling.gridSize(panes: ps)
            let vp = viewport(for: tree, cols: Int(grid.cols), rows: Int(grid.rows))
            let g = PaneCards.clientGrid(tree: tree, viewport: vp, cell: cell, metrics: m)
            #expect(g.cols == Int(grid.cols))
            #expect(g.rows == Int(grid.rows))
        }
    }

    /// A pane alone in its row has the same side padding as ones sharing theirs.
    @Test func sidePaddingIsTheSameHoweverARowIsSplit() throws {
        for layout in layouts {
            let ps = panes(layout)
            let tree = try #require(PaneCards.tree(layouts: [layout], panes: ps))
            let grid = PaneTiling.gridSize(panes: ps)
            let cards = PaneCards.cards(tree: tree, viewport: viewport(for: tree, cols: Int(grid.cols), rows: Int(grid.rows)),
                                        cell: cell, scale: 2, metrics: m)
            for card in cards.values {
                #expect(card.surfaceFrame.minX - card.frame.minX == m.padding)
                // The viewport's 3 spare points are the rightmost cards', all alike.
                let atRight = card.frame.maxX == viewport(for: tree, cols: Int(grid.cols), rows: Int(grid.rows)).width - m.gap
                #expect(card.frame.maxX - card.surfaceFrame.maxX == m.padding + (atRight ? 3 : 0))
            }
        }
    }

    @Test func gridLinesUpAcrossAnEven2x2() throws {
        let ps = panes(layouts[2])
        let tree = try #require(PaneCards.tree(layouts: [layouts[2]], panes: ps))
        let cards = PaneCards.cards(tree: tree, viewport: viewport(for: tree, cols: 81, rows: 41),
                                    cell: cell, scale: 2, metrics: m)
        func f(_ id: Int) -> CGRect { cards[TmuxPaneID(id)]!.frame }
        #expect(f(1).minY == f(3).minY && f(2).minY == f(4).minY)
        #expect(f(1).minX == f(2).minX && f(3).minX == f(4).minX)
        #expect(f(3).minX - f(1).maxX == m.gap)
        #expect(f(2).minY - f(1).maxY == m.gap)
    }

    @Test func inferredTreeMatchesTmuxs() throws {
        for layout in layouts {
            let ps = panes(layout)
            let real = try #require(PaneCards.tree(layouts: [layout], panes: ps))
            let guess = try #require(PaneCards.inferred(ps))
            #expect(PaneCards.chrome(real, cell: cell, metrics: m) == PaneCards.chrome(guess, cell: cell, metrics: m))
        }
    }

    /// Another window's layout (or none) must not be used.
    @Test func aForeignLayoutFallsBackToGeometry() {
        let ps = panes(layouts[0])
        #expect(PaneCards.tree(layouts: ["abcd,80x24,0,0,77"], panes: ps) == PaneCards.inferred(ps))
    }

    /// A grid another device sized isn't stretched to the window.
    @Test func aForeignGridKeepsItsNaturalSize() throws {
        let ps = panes(layouts[0])
        let tree = try #require(PaneCards.tree(layouts: [layouts[0]], panes: ps))
        let vp = viewport(for: tree, cols: 240, rows: 80)
        let cards = PaneCards.cards(tree: tree, viewport: vp, cell: cell, scale: 2, metrics: m)
        #expect(cards.values.map(\.frame.maxX).max()! < vp.width - 100)
    }
}
