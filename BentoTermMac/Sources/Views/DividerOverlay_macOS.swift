import BentoTmuxKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import BentoUISharedKit

// MARK: - Divider overlay (drag to resize)

/// A transparent overlay covering the whole host. It is hit-test-transparent
/// except within a few points of a divider between two adjacent panes, where it
/// claims the mouse to drag-resize (and shows a resize cursor). Everywhere else
/// clicks fall through to the panes.
@MainActor
final class DividerOverlay: NSView {
    weak var host: GhosttyTiledPaneHost?

    private var dividers: [PaneDivider] = []
    /// A pointer wants a thin band it can hit precisely; the iOS overlay's is
    /// far fatter (see `DividerHotZone`).
    private static let hotZone = DividerHotZone.symmetric(10)

    /// The drag in progress, if any — owns the cell-delta math and the live
    /// line position (shared with the iOS overlay).
    private var drag: DividerDrag?

    override var isFlipped: Bool { true }

    /// Recompute divider hot zones from the host's current cell frames.
    func refresh() {
        dividers = computeDividers()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: - Drawing (visual feedback)

    override func draw(_ dirtyRect: NSRect) {
        let lineColor = PaneChromeColors.isDark
            ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.18)
        for d in dividers {
            strokeLine(vertical: d.vertical, at: d.position, span: d.hotRect,
                       color: lineColor, width: 1)
        }
        // The line being dragged tracks the cursor live (tmux relayout lags
        // behind), drawn in the accent colour so the drag is clearly visible.
        if let drag {
            strokeLine(vertical: drag.divider.vertical, at: drag.livePosition,
                       span: drag.divider.hotRect,
                       color: GhosttyPaneColors.accentNSColor, width: 2)
        }
    }

    private func strokeLine(vertical: Bool, at pos: CGFloat, span: NSRect,
                            color: NSColor, width: CGFloat) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = width
        if vertical {
            path.move(to: NSPoint(x: pos, y: span.minY))
            path.line(to: NSPoint(x: pos, y: span.maxY))
        } else {
            path.move(to: NSPoint(x: span.minX, y: pos))
            path.line(to: NSPoint(x: span.maxX, y: pos))
        }
        path.stroke()
    }

    private func computeDividers() -> [PaneDivider] {
        guard let host else { return [] }
        return PaneTiling.dividers(frames: host.cellFrames, bounds: bounds.size,
                                   pointsPerCell: pointsPerCell() ?? CGPoint(x: 8, y: 8),
                                   hotZone: Self.hotZone)
    }

    private func divider(at point: NSPoint) -> PaneDivider? {
        dividers.first { $0.hotRect.contains(point) }
    }

    // Transparent except over a divider hot zone.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return divider(at: local) != nil ? self : nil
    }

    override func resetCursorRects() {
        for d in dividers {
            addCursorRect(d.hotRect, cursor: d.vertical ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        drag = divider(at: p).map { DividerDrag(divider: $0, startPoint: p) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host, drag != nil, let cellPts = pointsPerCell() else { return }
        let p = convert(event.locationInWindow, from: nil)
        let cells = drag!.advance(to: p, pointsPerCell: cellPts)
        needsDisplay = true   // the live line follows the cursor even between cells
        guard cells != 0 else { return }
        host.resizeBoundary(paneID: drag!.divider.paneID,
                            vertical: drag!.divider.vertical, deltaCells: cells)
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        needsDisplay = true
    }

    /// Points per tmux cell along each axis (proportional tiling = bounds / grid).
    private func pointsPerCell() -> CGPoint? {
        guard let host, bounds.width > 0, bounds.height > 0 else { return nil }
        let grid = host.paneGridSize
        guard grid.cols > 0, grid.rows > 0 else { return nil }
        return CGPoint(x: bounds.width / grid.cols, y: bounds.height / grid.rows)
    }
}
#endif
