import SwiftUI
import BentoTmuxKit
import Combine
import BentoVoiceKit
import BentoAgentKit
import BentoSessionKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

// MARK: - Divider overlay (drag to resize)

/// A transparent overlay over the tiled panes. It is touch-transparent except
/// within a few points of a divider between two adjacent panes, where it claims
/// the touch to drag-resize them (sends tmux `resize-pane`). Everywhere else,
/// touches fall through to the panes. iOS mirror of the macOS `DividerOverlay`.
final class TileDividerOverlay: UIView {
    /// Touch grab sizes (the pointer-driven macOS overlay uses a symmetric 10).
    /// Vertical dividers are CENTRED on the line. Horizontal dividers STRADDLE
    /// it — generous above (the upper pane's free surface) but only a little
    /// below, so the band sits on the border yet barely covers the lower pane's
    /// title bar, which is the drag-to-swap handle.
    static let hotZone = DividerHotZone(verticalThickness: 34, aboveLine: 26, belowLine: 6)

    var dividers: [PaneDivider] = [] { didSet { setNeedsDisplay() } }
    /// Points per tmux cell, set by the host so drag distance → cell delta.
    var pointsPerCell: CGPoint?
    /// (paneID, vertical, signed incremental cell delta) during a live drag.
    var onResize: ((TmuxPaneID, Bool, Int) -> Void)?

    /// The drag in progress — cell-delta math and live line position, shared
    /// with the macOS overlay.
    private var drag: DividerDrag?

    private static let accent = UIColor(red: 0.20, green: 0.80, blue: 0.55, alpha: 1.0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func divider(at point: CGPoint) -> PaneDivider? {
        dividers.first { $0.hotRect.contains(point) }
    }

    // Transparent except over a divider hot zone, so panes get all other touches.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        divider(at: point) != nil
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            let p = g.location(in: self)
            drag = divider(at: p).map { DividerDrag(divider: $0, startPoint: p) }
            setNeedsDisplay()
        case .changed:
            guard drag != nil, let ppc = pointsPerCell else { return }
            let cells = drag!.advance(to: g.location(in: self), pointsPerCell: ppc)
            setNeedsDisplay()   // the live line follows the finger even between cells
            guard cells != 0 else { return }
            onResize?(drag!.divider.paneID, drag!.divider.vertical, cells)
        default:
            drag = nil
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        for d in dividers {
            stroke(d, at: d.position, color: UIColor(white: 1, alpha: 0.30), width: 1.5)
        }
        // The line being dragged tracks the finger (tmux relayout lags), drawn in
        // the accent colour so the drag is clearly visible.
        if let drag {
            stroke(drag.divider, at: drag.livePosition, color: Self.accent, width: 2)
        }
    }

    private func stroke(_ d: PaneDivider, at pos: CGFloat, color: UIColor, width: CGFloat) {
        color.setStroke()
        let path = UIBezierPath()
        path.lineWidth = width
        if d.vertical {
            path.move(to: CGPoint(x: pos, y: d.hotRect.minY))
            path.addLine(to: CGPoint(x: pos, y: d.hotRect.maxY))
        } else {
            path.move(to: CGPoint(x: d.hotRect.minX, y: pos))
            path.addLine(to: CGPoint(x: d.hotRect.maxX, y: pos))
        }
        path.stroke()
    }
}
