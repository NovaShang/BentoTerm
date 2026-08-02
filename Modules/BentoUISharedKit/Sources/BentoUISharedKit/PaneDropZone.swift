import CoreGraphics

/// Where on a target pane a dragged pane may land — VS Code-style docking,
/// shared by the macOS and iOS tiled hosts. Center swaps the two panes; an
/// edge re-splits the target along that axis and docks the dragged pane on
/// that side. Geometry is in top-left-origin coordinates (UIKit's native
/// orientation; the macOS host view is flipped), so top = minY.
public enum PaneDropZone: Equatable, Sendable {
    case center, left, right, top, bottom

    /// Classify a point inside `frame`: the middle 50%×50% swaps; outside
    /// that, the nearest edge wins.
    public static func zone(at point: CGPoint, in frame: CGRect) -> PaneDropZone {
        guard frame.width > 0, frame.height > 0 else { return .center }
        let u = (point.x - frame.minX) / frame.width
        let v = (point.y - frame.minY) / frame.height
        if (0.25...0.75).contains(u), (0.25...0.75).contains(v) { return .center }
        let edges: [(CGFloat, PaneDropZone)] =
            [(u, .left), (1 - u, .right), (v, .top), (1 - v, .bottom)]
        return edges.min { $0.0 < $1.0 }!.1
    }

    /// The region of the target the drop will occupy — what the landing
    /// preview highlights: the whole pane for a swap, the docked half for an
    /// edge.
    public func highlightRect(in frame: CGRect) -> CGRect {
        switch self {
        case .center:
            return frame
        case .left:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right:
            return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom:
            return CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }

    /// The tmux landing for an edge zone — the split axis and side that
    /// `TerminalViewModel.movePane(_:splitting:horizontal:before:)` takes
    /// (`move-pane -h/-v [-b]`). nil for center (= swap).
    public var dock: (horizontal: Bool, before: Bool)? {
        switch self {
        case .center: return nil
        case .left:   return (horizontal: true, before: true)
        case .right:  return (horizontal: true, before: false)
        case .top:    return (horizontal: false, before: true)
        case .bottom: return (horizontal: false, before: false)
        }
    }
}
