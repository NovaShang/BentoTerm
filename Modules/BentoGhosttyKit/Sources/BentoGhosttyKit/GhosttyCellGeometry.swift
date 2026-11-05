import CoreGraphics
import BentoFoundationKit

/// The engine's cell grid in view points. libghostty reports cell sizes in
/// device pixels while mouse input and every view coordinate are in points, so
/// each surface divides by the scale it renders at — iOS by `renderScale`, the
/// Mac by its backing scale. Both surfaces used to carry their own copy of
/// these few lines; one wrong divisor here is the "selection lands on row 2n"
/// class of bug, so the arithmetic lives once.
public enum GhosttyCellGeometry {
    /// One cell's size in points, or nil until the engine has reported a size.
    public static func cellSize(_ size: TerminalSurfaceSize?, scale: CGFloat) -> CGSize? {
        guard let size, size.cellWidthPx > 0, size.cellHeightPx > 0, scale > 0 else { return nil }
        return CGSize(width: CGFloat(size.cellWidthPx) / scale,
                      height: CGFloat(size.cellHeightPx) / scale)
    }

    /// The 1-based (col, row) under a view point. (1, 1) before the engine has
    /// a size — a mouse report needs SOME cell, and the top-left one is the
    /// least surprising.
    public static func cell(at point: CGPoint, size: TerminalSurfaceSize?,
                            scale: CGFloat) -> (col: Int, row: Int) {
        guard let cell = cellSize(size, scale: scale) else { return (1, 1) }
        return (max(1, Int(point.x / cell.width) + 1),
                max(1, Int(point.y / cell.height) + 1))
    }
}

/// Turns continuous scroll travel (a pan, a trackpad) into whole rows, keeping
/// the remainder so slow travel still adds up. Used for copy-mode scrolling and
/// for wheel reports to a mouse-owning program; callers cap the burst
/// themselves, because what a flick may cost differs between the two.
public struct ScrollRowAccumulator: Equatable, Sendable {
    private var travel: CGFloat = 0

    public init() {}

    /// Forget leftover travel — a fresh gesture starts from zero.
    public mutating func reset() { travel = 0 }

    /// Add `delta` points of travel; return the whole rows (signed) it crossed
    /// at `rowHeight` points per row, keeping the fraction for next time.
    public mutating func rows(adding delta: CGFloat, rowHeight: CGFloat) -> Int {
        guard rowHeight > 0 else { return 0 }
        travel += delta
        let rows = Int(travel / rowHeight)
        travel -= CGFloat(rows) * rowHeight
        return rows
    }
}
