import CoreGraphics
import BentoTmuxKit

/// The geometry of a tiled pane grid: where each pane's container goes, where
/// the draggable boundaries between them are, and what client size the whole
/// thing asks tmux for.
///
/// Pure functions over tmux cell coordinates — no view types, so the macOS and
/// iOS hosts compute identical geometry and differ only in what they hang on
/// it (NSView vs UIView, mouse vs touch). Both hosts previously carried their
/// own copy of every formula here, down to the same tolerances.
///
/// Coordinates are top-left origin (UIKit's native orientation; the macOS host
/// view is flipped), matching `PaneDropZone`.
public enum PaneTiling {

    /// The bounding box of all panes, in tmux cells — the grid the tiles fill.
    public static func gridSize(panes: [Pane]) -> (cols: CGFloat, rows: CGFloat) {
        let cols = panes.map { $0.x + $0.width }.max() ?? 1
        let rows = panes.map { $0.y + $0.height }.max() ?? 1
        return (CGFloat(max(cols, 1)), CGFloat(max(rows, 1)))
    }

    /// Cell-exact tiling: map tmux cell geometry 1:1 to points.
    ///
    /// Each pane is a title bar (one cell tall, sitting in tmux's divider row)
    /// plus a surface of exactly its cols×rows, so ghostty's grid equals the
    /// grid tmux assigned the pane and TUIs never tear. Stacked panes abut
    /// through the title bar — only the top one adds height. Side-by-side panes
    /// share the divider column: each container grows half a cell into it on
    /// both sides so neighbours meet (borders and highlights land on the divider
    /// centerline, no visible gap), while `surfaceInsetX` keeps the surface at
    /// its true size and position.
    ///
    /// `titleBarHeight` defaults to that one cell; pass 0 for a layout that
    /// hides the strip entirely (macOS List mode, where the sidebar already
    /// names the pane).
    public static func cellExactTiles(panes: [Pane], pointsPerCell ppc: CGSize,
                                      titleBarHeight: CGFloat? = nil) -> [PaneTile] {
        let titleBar = titleBarHeight ?? ppc.height
        let halfGap = ppc.width / 2
        return panes.map { p in
            PaneTile(
                id: p.id,
                frame: CGRect(x: CGFloat(p.x) * ppc.width - halfGap,
                              y: CGFloat(p.y) * ppc.height,
                              width: CGFloat(p.width) * ppc.width + 2 * halfGap,
                              height: titleBar + CGFloat(p.height) * ppc.height),
                surfaceInsetX: halfGap,
                titleBarHeight: titleBar)
        }
    }

    /// Proportional tiling — the bootstrap before any surface has reported its
    /// cell size. Panes fill `page` in proportion to their cell geometry, which
    /// gets the surfaces on screen so they report metrics; the next pass runs
    /// cell-exact.
    public static func proportionalTiles(panes: [Pane], page: CGSize,
                                         titleBarHeight: CGFloat) -> [PaneTile] {
        let (cols, rows) = gridSize(panes: panes)
        return panes.map { p in
            PaneTile(
                id: p.id,
                frame: CGRect(x: (CGFloat(p.x) / cols) * page.width,
                              y: (CGFloat(p.y) / rows) * page.height,
                              width: (CGFloat(p.width) / cols) * page.width,
                              height: (CGFloat(p.height) / rows) * page.height),
                surfaceInsetX: 0,
                titleBarHeight: titleBarHeight)
        }
    }

    /// The size the whole tiled page occupies: the grid 1:1, plus exactly ONE
    /// title bar of height (stacked panes reuse divider rows — see
    /// `cellExactTiles`).
    public static func pageSize(gridCols: CGFloat, gridRows: CGFloat,
                                pointsPerCell ppc: CGSize) -> CGSize {
        CGSize(width: gridCols * ppc.width, height: (gridRows + 1) * ppc.height)
    }

    /// The tmux client size for a viewport showing tiles: cells that fit, minus
    /// the one row of height the top pane's title bar takes.
    public static func clientGrid(viewport: CGSize, cellPixels: CGSize,
                                  scale: CGFloat) -> (cols: Int, rows: Int) {
        guard cellPixels.width > 0, cellPixels.height > 0 else { return (2, 1) }
        let cols = max(Int((viewport.width * scale) / cellPixels.width), 2)
        let rows = max(Int((viewport.height * scale - cellPixels.height) / cellPixels.height), 1)
        return (cols, rows)
    }

    /// The draggable boundaries between adjacent panes.
    ///
    /// Tiling leaves tmux's divider column/row between neighbours, so adjacent
    /// panes don't share a coincident edge: match across that gap (up to ~2
    /// cells) and put the boundary on its centerline. A pane owns the boundary
    /// on its right and bottom; `hotZone` sizes the grab area for the input
    /// device.
    public static func dividers(frames: [PaneFrame], bounds: CGSize,
                                pointsPerCell ppc: CGPoint,
                                hotZone: DividerHotZone) -> [PaneDivider] {
        guard frames.count > 1 else { return [] }
        let gapTolX = max(ppc.x * 1.8, 6)
        let gapTolY = max(ppc.y * 1.8, 6)
        let eps: CGFloat = 2
        var result: [PaneDivider] = []

        for a in frames {
            // Vertical divider: a pane sits just to the right of a's right edge.
            let rightEdge = a.frame.maxX
            if rightEdge < bounds.width - eps {
                let neighbors = frames.filter {
                    $0.frame.minX > rightEdge - eps
                        && $0.frame.minX - rightEdge < gapTolX
                        && yOverlap($0.frame, a.frame) > eps
                }
                if let nearest = neighbors.map(\.frame.minX).min() {
                    let pos = (rightEdge + nearest) / 2
                    let yTop = neighbors.map { max($0.frame.minY, a.frame.minY) }.min() ?? a.frame.minY
                    let yBot = neighbors.map { min($0.frame.maxY, a.frame.maxY) }.max() ?? a.frame.maxY
                    result.append(PaneDivider(
                        paneID: a.id, vertical: true, position: pos,
                        hotRect: CGRect(x: pos - hotZone.verticalThickness / 2, y: yTop,
                                        width: hotZone.verticalThickness, height: yBot - yTop)))
                }
            }
            // Horizontal divider: a pane sits just below a's bottom edge.
            let bottomEdge = a.frame.maxY
            if bottomEdge < bounds.height - eps {
                let neighbors = frames.filter {
                    $0.frame.minY > bottomEdge - eps
                        && $0.frame.minY - bottomEdge < gapTolY
                        && xOverlap($0.frame, a.frame) > eps
                }
                if let nearest = neighbors.map(\.frame.minY).min() {
                    let pos = (bottomEdge + nearest) / 2
                    let xL = neighbors.map { max($0.frame.minX, a.frame.minX) }.min() ?? a.frame.minX
                    let xR = neighbors.map { min($0.frame.maxX, a.frame.maxX) }.max() ?? a.frame.maxX
                    result.append(PaneDivider(
                        paneID: a.id, vertical: false, position: pos,
                        hotRect: CGRect(x: xL, y: pos - hotZone.aboveLine,
                                        width: xR - xL,
                                        height: hotZone.aboveLine + hotZone.belowLine)))
                }
            }
        }
        return result
    }

    /// tmux `resize-pane` direction for a signed cell delta on a boundary.
    /// Vertical divider → grow Right / shrink Left; horizontal → Down / Up.
    public static func resizeDirection(vertical: Bool, deltaCells: Int) -> String? {
        guard deltaCells != 0 else { return nil }
        if vertical { return deltaCells > 0 ? "R" : "L" }
        return deltaCells > 0 ? "D" : "U"
    }

    private static func yOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxY, b.maxY) - max(a.minY, b.minY)
    }

    private static func xOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxX, b.maxX) - max(a.minX, b.minX)
    }
}

/// One pane's placement in the tiled grid.
public struct PaneTile: Equatable, Sendable {
    public let id: TmuxPaneID
    /// The container's frame — title bar on top, surface below.
    public let frame: CGRect
    /// How far the surface is inset horizontally inside the container, so it
    /// keeps its exact cell size while the container spans the divider column.
    public let surfaceInsetX: CGFloat
    public let titleBarHeight: CGFloat

    public init(id: TmuxPaneID, frame: CGRect, surfaceInsetX: CGFloat, titleBarHeight: CGFloat) {
        self.id = id
        self.frame = frame
        self.surfaceInsetX = surfaceInsetX
        self.titleBarHeight = titleBarHeight
    }
}

/// A pane container's current on-screen frame — the input to divider and drop
/// hit-testing.
public struct PaneFrame: Equatable, Sendable {
    public let id: TmuxPaneID
    public let frame: CGRect

    public init(id: TmuxPaneID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// A draggable boundary: the pane that owns it, its orientation, the line's
/// position (x for vertical, y for horizontal) and the area that grabs it.
public struct PaneDivider: Equatable, Sendable {
    public let paneID: TmuxPaneID
    public let vertical: Bool
    public let position: CGFloat
    public let hotRect: CGRect

    public init(paneID: TmuxPaneID, vertical: Bool, position: CGFloat, hotRect: CGRect) {
        self.paneID = paneID
        self.vertical = vertical
        self.position = position
        self.hotRect = hotRect
    }
}

/// How big a divider's grab area is. A pointer wants a thin band centred on the
/// line; a finger wants a fat one, and asymmetric for horizontal dividers — a
/// generous reach into the upper pane's free surface but barely any below, so
/// the band doesn't swallow the lower pane's title bar (the drag-to-swap
/// handle).
public struct DividerHotZone: Equatable, Sendable {
    public let verticalThickness: CGFloat
    public let aboveLine: CGFloat
    public let belowLine: CGFloat

    public init(verticalThickness: CGFloat, aboveLine: CGFloat, belowLine: CGFloat) {
        self.verticalThickness = verticalThickness
        self.aboveLine = aboveLine
        self.belowLine = belowLine
    }

    /// Centred on the line in both axes — the pointer-device shape.
    public static func symmetric(_ thickness: CGFloat) -> DividerHotZone {
        DividerHotZone(verticalThickness: thickness,
                       aboveLine: thickness / 2, belowLine: thickness / 2)
    }
}

/// A divider drag in progress: converts pointer/finger movement into the
/// incremental cell deltas tmux's `resize-pane` wants, and tracks the live line
/// position so the host can draw the boundary following the cursor (tmux's
/// relayout lags behind the drag).
public struct DividerDrag {
    public let divider: PaneDivider
    /// The dragged line's current coordinate (x for vertical, y for horizontal).
    public private(set) var livePosition: CGFloat

    private let start: CGPoint
    private var sentCells = 0

    public init(divider: PaneDivider, startPoint: CGPoint) {
        self.divider = divider
        self.start = startPoint
        self.livePosition = divider.vertical ? startPoint.x : startPoint.y
    }

    /// Advance the drag to `point`. Returns the cell delta still to send — 0
    /// when the movement hasn't crossed another cell boundary yet, so the host
    /// can skip the tmux round-trip.
    public mutating func advance(to point: CGPoint, pointsPerCell ppc: CGPoint) -> Int {
        livePosition = divider.vertical ? point.x : point.y
        let perCell = divider.vertical ? ppc.x : ppc.y
        guard perCell > 0 else { return 0 }
        let deltaPoints = divider.vertical ? (point.x - start.x) : (point.y - start.y)
        let totalCells = Int((deltaPoints / perCell).rounded())
        let incremental = totalCells - sentCells
        guard incremental != 0 else { return 0 }
        sentCells = totalCells
        return incremental
    }
}
