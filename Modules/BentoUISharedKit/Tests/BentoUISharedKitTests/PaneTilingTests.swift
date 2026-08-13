import Testing
import CoreGraphics
import BentoTmuxKit
@testable import BentoUISharedKit

/// The tiled-grid geometry both hosts render. It was two hand-copied
/// implementations with no tests until 2026-08-07; these pin the invariants the
/// layout depends on (see PaneTiling).
struct PaneTilingTests {

    /// A pane at cell (x, y) sized w×h. Only the geometry fields matter here.
    private func pane(_ id: Int, x: Int, y: Int, w: Int, h: Int) -> Pane {
        Pane(id: TmuxPaneID(id), width: w, height: h, x: x, y: y,
             isActive: false, currentCommand: nil, title: nil)
    }

    /// Two panes side by side, sharing tmux's divider column at x = 40.
    private var sideBySide: [Pane] {
        [pane(1, x: 0, y: 0, w: 40, h: 20), pane(2, x: 41, y: 0, w: 39, h: 20)]
    }

    /// Two panes stacked, sharing tmux's divider row at y = 20.
    private var stacked: [Pane] {
        [pane(1, x: 0, y: 0, w: 80, h: 20), pane(2, x: 0, y: 21, w: 80, h: 19)]
    }

    private let ppc = CGSize(width: 8, height: 16)

    @Test func gridSizeIsTheBoundingBox() {
        let (cols, rows) = PaneTiling.gridSize(panes: sideBySide)
        #expect(cols == 80)
        #expect(rows == 20)
    }

    @Test func gridSizeOfNothingIsOneCell() {
        let (cols, rows) = PaneTiling.gridSize(panes: [])
        #expect(cols == 1)
        #expect(rows == 1)
    }

    /// A pane's surface must occupy exactly its tmux cols×rows, with the title
    /// bar adding one cell of height on top — the invariant that keeps ghostty's
    /// grid equal to tmux's (anything else tears TUIs).
    @Test func tileIsCellExactPlusOneTitleBar() {
        let tiles = PaneTiling.cellExactTiles(panes: sideBySide, pointsPerCell: ppc)
        let first = tiles.first { $0.id == TmuxPaneID(1) }!
        #expect(first.titleBarHeight == 16)
        #expect(first.frame.height == CGFloat(16 + 20 * 16))
        // Width spans the pane plus half the divider column on each side.
        #expect(first.frame.width == CGFloat(40 * 8 + 8))
        #expect(first.frame.minX == -4)
    }

    /// Side-by-side neighbours must MEET: each grows half a cell into the shared
    /// divider column, so there's no visible gap between tiles.
    @Test func sideBySideTilesMeetOnTheDividerCenterline() {
        let tiles = PaneTiling.cellExactTiles(panes: sideBySide, pointsPerCell: ppc)
        let left = tiles.first { $0.id == TmuxPaneID(1) }!
        let right = tiles.first { $0.id == TmuxPaneID(2) }!
        #expect(left.frame.maxX == right.frame.minX)
    }

    /// Stacked panes abut through the lower pane's title bar — it sits in tmux's
    /// divider row, so only the top pane adds height.
    @Test func stackedTilesAbutThroughTheTitleBar() {
        let tiles = PaneTiling.cellExactTiles(panes: stacked, pointsPerCell: ppc)
        let top = tiles.first { $0.id == TmuxPaneID(1) }!
        let bottom = tiles.first { $0.id == TmuxPaneID(2) }!
        #expect(top.frame.maxY == bottom.frame.minY)
    }

    @Test func hiddenTitleBarGivesItsCellBackToTheSurface() {
        let tiles = PaneTiling.cellExactTiles(panes: stacked, pointsPerCell: ppc,
                                              titleBarHeight: 0)
        #expect(tiles[0].frame.height == CGFloat(20 * 16))
    }

    @Test func pageReservesExactlyOneTitleBarRow() {
        let (cols, rows) = PaneTiling.gridSize(panes: stacked)
        let page = PaneTiling.pageSize(gridCols: cols, gridRows: rows, pointsPerCell: ppc)
        #expect(page.width == CGFloat(80 * 8))
        #expect(page.height == CGFloat((40 + 1) * 16))
    }

    /// The client grid gives tmux the rows that are actually usable — the
    /// viewport minus the one row the top title bar occupies.
    @Test func clientGridSubtractsTheTitleBarRow() {
        let grid = PaneTiling.clientGrid(viewport: CGSize(width: 800, height: 600),
                                         cellPixels: CGSize(width: 16, height: 32),
                                         scale: 2)
        #expect(grid.cols == 100)          // 800 * 2 / 16
        #expect(grid.rows == 36)           // 600 * 2 / 32 = 37.5 → 37, minus the bar
    }

    @Test func clientGridNeverGoesDegenerate() {
        let grid = PaneTiling.clientGrid(viewport: .zero,
                                         cellPixels: CGSize(width: 8, height: 16), scale: 2)
        #expect(grid.cols == 2)
        #expect(grid.rows == 1)
    }

    // MARK: - Dividers

    private func frames(_ tiles: [PaneTile]) -> [PaneFrame] {
        tiles.map { PaneFrame(id: $0.id, frame: $0.frame) }
    }

    @Test func aLonePaneHasNoDividers() {
        let tiles = PaneTiling.cellExactTiles(panes: [pane(1, x: 0, y: 0, w: 80, h: 20)],
                                              pointsPerCell: ppc)
        #expect(PaneTiling.dividers(frames: frames(tiles), bounds: CGSize(width: 640, height: 336),
                                    pointsPerCell: CGPoint(x: 8, y: 16),
                                    hotZone: .symmetric(10)).isEmpty)
    }

    @Test func sideBySidePanesGetOneVerticalDivider() {
        let tiles = PaneTiling.cellExactTiles(panes: sideBySide, pointsPerCell: ppc)
        let dividers = PaneTiling.dividers(frames: frames(tiles),
                                           bounds: CGSize(width: 640, height: 336),
                                           pointsPerCell: CGPoint(x: 8, y: 16),
                                           hotZone: .symmetric(10))
        #expect(dividers.count == 1)
        let d = dividers[0]
        #expect(d.vertical)
        #expect(d.paneID == TmuxPaneID(1))     // the LEFT pane owns the boundary
        #expect(d.position == 324)             // the centerline where the tiles meet
        #expect(d.hotRect.width == 10)
        #expect(d.hotRect.midX == d.position)
    }

    @Test func stackedPanesGetOneHorizontalDivider() {
        let tiles = PaneTiling.cellExactTiles(panes: stacked, pointsPerCell: ppc)
        let dividers = PaneTiling.dividers(frames: frames(tiles),
                                           bounds: CGSize(width: 640, height: 672),
                                           pointsPerCell: CGPoint(x: 8, y: 16),
                                           hotZone: .symmetric(10))
        #expect(dividers.count == 1)
        #expect(!dividers[0].vertical)
        #expect(dividers[0].paneID == TmuxPaneID(1))   // the UPPER pane owns it
    }

    /// A boundary at the container's own edge isn't draggable — there's no
    /// neighbour on the far side, just the window frame.
    @Test func edgesOfTheGridAreNotDividers() {
        let tiles = PaneTiling.cellExactTiles(panes: sideBySide, pointsPerCell: ppc)
        // Bounds ending exactly at the right pane's edge: its right boundary is
        // the window edge, so only the middle divider survives.
        let bounds = CGSize(width: tiles.map(\.frame.maxX).max()!, height: 336)
        let dividers = PaneTiling.dividers(frames: frames(tiles), bounds: bounds,
                                           pointsPerCell: CGPoint(x: 8, y: 16),
                                           hotZone: .symmetric(10))
        #expect(dividers.count == 1)
    }

    /// The touch hot zone straddles a horizontal line asymmetrically so it can't
    /// swallow the lower pane's title bar (the drag-to-swap handle).
    @Test func touchHotZoneLeansAboveAHorizontalDivider() {
        let tiles = PaneTiling.cellExactTiles(panes: stacked, pointsPerCell: ppc)
        let zone = DividerHotZone(verticalThickness: 34, aboveLine: 26, belowLine: 6)
        let d = PaneTiling.dividers(frames: frames(tiles),
                                    bounds: CGSize(width: 640, height: 672),
                                    pointsPerCell: CGPoint(x: 8, y: 16),
                                    hotZone: zone)[0]
        #expect(d.hotRect.minY == d.position - 26)
        #expect(d.hotRect.maxY == d.position + 6)
    }

    // MARK: - Resize

    @Test func resizeDirectionsFollowTheDragSign() {
        #expect(PaneTiling.resizeDirection(vertical: true, deltaCells: 3) == "R")
        #expect(PaneTiling.resizeDirection(vertical: true, deltaCells: -3) == "L")
        #expect(PaneTiling.resizeDirection(vertical: false, deltaCells: 2) == "D")
        #expect(PaneTiling.resizeDirection(vertical: false, deltaCells: -2) == "U")
        #expect(PaneTiling.resizeDirection(vertical: true, deltaCells: 0) == nil)
    }

    /// A drag reports each cell boundary it crosses exactly once — the deltas
    /// are incremental, so replaying them sums to the total movement (sending
    /// the cumulative value instead would resize by the triangular number).
    @Test func dividerDragSendsEachCellOnce() {
        let divider = PaneDivider(paneID: TmuxPaneID(1), vertical: true, position: 100,
                                  hotRect: CGRect(x: 95, y: 0, width: 10, height: 300))
        var drag = DividerDrag(divider: divider, startPoint: CGPoint(x: 100, y: 50))
        let ppc = CGPoint(x: 8, y: 16)

        #expect(drag.advance(to: CGPoint(x: 103, y: 50), pointsPerCell: ppc) == 0)  // <½ cell
        #expect(drag.advance(to: CGPoint(x: 108, y: 50), pointsPerCell: ppc) == 1)
        #expect(drag.advance(to: CGPoint(x: 124, y: 50), pointsPerCell: ppc) == 2)
        #expect(drag.advance(to: CGPoint(x: 108, y: 50), pointsPerCell: ppc) == -2) // dragged back
        #expect(drag.livePosition == 108)
    }

    @Test func dividerDragTracksTheAxisItOwns() {
        let horizontal = PaneDivider(paneID: TmuxPaneID(1), vertical: false, position: 200,
                                     hotRect: CGRect(x: 0, y: 195, width: 300, height: 10))
        var drag = DividerDrag(divider: horizontal, startPoint: CGPoint(x: 10, y: 200))
        // Horizontal movement must not resize a horizontal divider.
        #expect(drag.advance(to: CGPoint(x: 300, y: 200), pointsPerCell: CGPoint(x: 8, y: 16)) == 0)
        #expect(drag.advance(to: CGPoint(x: 300, y: 232), pointsPerCell: CGPoint(x: 8, y: 16)) == 2)
        #expect(drag.livePosition == 232)
    }
}
