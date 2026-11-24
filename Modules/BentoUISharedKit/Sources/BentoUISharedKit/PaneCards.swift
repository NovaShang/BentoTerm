import CoreGraphics
import BentoTmuxKit

/// The measures of the card look: panes as rounded cards on a desk.
public struct PaneCardMetrics: Equatable, Sendable {
    /// Between two cards, the same both ways.
    public let gap: CGFloat
    /// Round the outside of the whole grid.
    public let margin: CGFloat
    /// Card padding left and right of the surface.
    public let padding: CGFloat
    /// Card padding below the surface.
    public let bottomPadding: CGFloat
    public let titleHeight: CGFloat
    public let cornerRadius: CGFloat

    public init(gap: CGFloat, margin: CGFloat, padding: CGFloat,
                bottomPadding: CGFloat, titleHeight: CGFloat, cornerRadius: CGFloat) {
        self.gap = gap
        self.margin = margin
        self.padding = padding
        self.bottomPadding = bottomPadding
        self.titleHeight = titleHeight
        self.cornerRadius = cornerRadius
    }

    /// The Mac's measures for a cell of `cell` points.
    ///
    /// Side by side, two paddings and a gap are exactly the divider column tmux
    /// already spends, so a row costs the same width however many panes it
    /// holds and every card has the same padding. (With more than that, a pane
    /// alone in its row wears what its neighbours' extra gaps cost.) The
    /// same gap runs round the outside. The card clips the surface's corners,
    /// whose arc runs about where a corner glyph's ink ends.
    public static func mac(cell: CGSize) -> PaneCardMetrics {
        // Whole points, so surfaces land on device pixels at 1× too.
        let padding = max(((cell.width - 4) / 2).rounded(.down), 1)
        let gap = max(cell.width - 2 * padding, 3)
        return PaneCardMetrics(gap: gap, margin: gap, padding: padding,
                               bottomPadding: 2, titleHeight: 28, cornerRadius: 14)
    }
}

/// One pane laid out as a card, in host coordinates (top-left origin).
public struct PaneCard: Equatable, Sendable {
    public let frame: CGRect
    /// The terminal surface: exactly the pane's cols×rows cells.
    public let surfaceFrame: CGRect

    /// The surface's frame inside the card.
    public var surfaceFrameInCard: CGRect {
        surfaceFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }
}

/// Card tiling: what `PaneTiling.cellExactTiles` can't do, because it maps the
/// whole page 1:1 to tmux cells and so has only tmux's one-cell dividers to
/// decorate.
///
/// Here only the SURFACES are cell-exact (the invariant that keeps TUIs from
/// tearing). The cards round them are laid out natively along tmux's split
/// tree, with whatever gap, title and padding the metrics ask for, and the
/// client grid is what's left of the viewport after that chrome:
///
///   chrome(leaf)   = (2·padding, title + bottomPadding)
///   chrome(h-split) = Σ chrome(child).w + (n−1)·(gap − cellW),  max chrome(child).h
///   chrome(v-split) = max chrome(child).w,  Σ chrome(child).h + (n−1)·(gap − cellH)
///
/// (a gap replaces the divider cell tmux already spent). It depends on the
/// split structure alone, never on the pane sizes, so the resize it causes
/// can't change it: the size pushed to tmux settles in one step.
///
/// A stack with fewer titles than the deepest one has the difference left over;
/// its last card takes it, below the surface.
public enum PaneCards {

    /// tmux's split tree for `panes`: the first of `layouts` (newest first)
    /// that names one of them, leaves resized to the panes' current geometry;
    /// failing that, the tree read back from the geometry itself.
    ///
    /// Leaf ids are matched, not sizes: between a split or a close and the next
    /// pane listing, the layout string already knows the new structure while
    /// the pane list doesn't, and laying out by it avoids a transient.
    public static func tree(layouts: [String], panes: [Pane]) -> TmuxLayoutTree.Node? {
        let byID = Dictionary(panes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for layout in layouts {
            guard let node = TmuxLayoutTree.parse(layout),
                  TmuxLayoutTree.leafOrder(of: node).contains(where: { byID[TmuxPaneID($0)] != nil })
            else { continue }
            return resized(node, byID)
        }
        return inferred(panes)
    }

    private static func resized(_ node: TmuxLayoutTree.Node,
                                _ panes: [TmuxPaneID: Pane]) -> TmuxLayoutTree.Node {
        switch node {
        case .leaf(let id, _, _, _, _):
            guard let p = panes[TmuxPaneID(id)] else { return node }
            return .leaf(id: id, w: p.width, h: p.height, x: p.x, y: p.y)
        case .hsplit(let w, let h, let x, let y, let c):
            return .hsplit(w: w, h: h, x: x, y: y, children: c.map { resized($0, panes) })
        case .vsplit(let w, let h, let x, let y, let c):
            return .vsplit(w: w, h: h, x: x, y: y, children: c.map { resized($0, panes) })
        }
    }

    /// The split tree from geometry alone: cut at every column (else every row)
    /// no pane crosses, and recurse. nil when neither cut exists.
    static func inferred(_ panes: [Pane]) -> TmuxLayoutTree.Node? {
        guard let first = panes.first else { return nil }
        if panes.count == 1 {
            return .leaf(id: first.id.raw, w: first.width, h: first.height, x: first.x, y: first.y)
        }
        func groups(_ lo: (Pane) -> Int, _ hi: (Pane) -> Int) -> [[Pane]] {
            var out: [[Pane]] = []
            var end = Int.min
            for p in panes.sorted(by: { lo($0) < lo($1) }) {
                if out.isEmpty || lo(p) >= end { out.append([p]) } else { out[out.count - 1].append(p) }
                end = max(end, hi(p))
            }
            return out
        }
        let cols = groups({ $0.x }, { $0.x + $0.width })
        let rows = groups({ $0.y }, { $0.y + $0.height })
        let parts = cols.count > 1 ? cols : rows
        guard parts.count > 1 else { return nil }
        let children = parts.compactMap(inferred)
        guard children.count == parts.count else { return nil }
        let x = panes.map(\.x).min()!, y = panes.map(\.y).min()!
        let w = panes.map { $0.x + $0.width }.max()! - x
        let h = panes.map { $0.y + $0.height }.max()! - y
        return cols.count > 1 ? .hsplit(w: w, h: h, x: x, y: y, children: children)
                              : .vsplit(w: w, h: h, x: x, y: y, children: children)
    }

    /// Points a tree needs beyond its tmux cells.
    static func chrome(_ node: TmuxLayoutTree.Node, cell: CGSize, metrics m: PaneCardMetrics) -> CGSize {
        switch node {
        case .leaf:
            return CGSize(width: 2 * m.padding, height: m.titleHeight + m.bottomPadding)
        case .hsplit(_, _, _, _, let children):
            let c = children.map { chrome($0, cell: cell, metrics: m) }
            return CGSize(width: c.map(\.width).reduce(0, +) + CGFloat(c.count - 1) * (m.gap - cell.width),
                          height: c.map(\.height).max() ?? 0)
        case .vsplit(_, _, _, _, let children):
            let c = children.map { chrome($0, cell: cell, metrics: m) }
            return CGSize(width: c.map(\.width).max() ?? 0,
                          height: c.map(\.height).reduce(0, +) + CGFloat(c.count - 1) * (m.gap - cell.height))
        }
    }

    /// The tmux client size for a viewport showing `tree` as cards.
    public static func clientGrid(tree: TmuxLayoutTree.Node, viewport: CGSize, cell: CGSize,
                                  metrics m: PaneCardMetrics) -> (cols: Int, rows: Int) {
        guard cell.width > 0, cell.height > 0 else { return (2, 1) }
        let c = chrome(tree, cell: cell, metrics: m)
        // A hair of tolerance: the sum is meant to land on a whole cell.
        let cols = Int((viewport.width - 2 * m.margin - c.width) / cell.width + 0.001)
        let rows = Int((viewport.height - 2 * m.margin - c.height) / cell.height + 0.001)
        return (max(cols, 2), max(rows, 1))
    }

    /// Points a tree needs to show every pane at its exact cols×rows.
    static func required(_ node: TmuxLayoutTree.Node, cell: CGSize, metrics m: PaneCardMetrics) -> CGSize {
        switch node {
        case .leaf(_, let w, let h, _, _):
            return CGSize(width: CGFloat(w) * cell.width + 2 * m.padding,
                          height: m.titleHeight + CGFloat(h) * cell.height + m.bottomPadding)
        case .hsplit(_, _, _, _, let children):
            let c = children.map { required($0, cell: cell, metrics: m) }
            return CGSize(width: c.map(\.width).reduce(0, +) + CGFloat(c.count - 1) * m.gap,
                          height: c.map(\.height).max() ?? 0)
        case .vsplit(_, _, _, _, let children):
            let c = children.map { required($0, cell: cell, metrics: m) }
            return CGSize(width: c.map(\.width).max() ?? 0,
                          height: c.map(\.height).reduce(0, +) + CGFloat(c.count - 1) * m.gap)
        }
    }

    /// Every leaf's card. The sub-cell remainder of `clientGrid`'s floor goes to
    /// the rightmost card of each row and the bottom one of each column, so the
    /// margins stay equal. More than that
    /// left over means the grid isn't ours (another device sizes the session,
    /// or a resize is on its way), and the cards keep their natural size.
    public static func cards(tree: TmuxLayoutTree.Node, viewport: CGSize, cell: CGSize, scale: CGFloat,
                             metrics m: PaneCardMetrics) -> [TmuxPaneID: PaneCard] {
        guard cell.width > 0, cell.height > 0 else { return [:] }
        let s = max(scale, 1)
        func px(_ v: CGFloat) -> CGFloat { (v * s).rounded(.down) / s }
        func remainder(_ need: CGFloat, _ have: CGFloat, _ unit: CGFloat) -> CGFloat {
            let spare = have - need
            return spare > 0 && spare < unit + 0.5 ? px(spare) : 0
        }
        let need = required(tree, cell: cell, metrics: m)
        let spareX = remainder(need.width, viewport.width - 2 * m.margin, cell.width)
        let spareY = remainder(need.height, viewport.height - 2 * m.margin, cell.height)
        let root = CGRect(x: m.margin, y: m.margin,
                          width: need.width + spareX, height: need.height + spareY)
        var out: [TmuxPaneID: PaneCard] = [:]

        func place(_ node: TmuxLayoutTree.Node, _ rect: CGRect) {
            switch node {
            case .leaf(let id, let w, let h, _, _):
                let size = CGSize(width: CGFloat(w) * cell.width, height: CGFloat(h) * cell.height)
                out[TmuxPaneID(id)] = PaneCard(
                    frame: rect,
                    surfaceFrame: CGRect(x: rect.minX + m.padding,
                                         y: rect.minY + m.titleHeight,
                                         width: size.width, height: size.height))
            case .hsplit(_, _, _, _, let children):
                let needs = children.map { required($0, cell: cell, metrics: m).width }
                for (child, span) in zip(children, spans(needs, from: rect.minX, total: rect.width)) {
                    place(child, CGRect(x: span.at, y: rect.minY, width: span.length, height: rect.height))
                }
            case .vsplit(_, _, _, _, let children):
                let needs = children.map { required($0, cell: cell, metrics: m).height }
                for (child, span) in zip(children, spans(needs, from: rect.minY, total: rect.height)) {
                    place(child, CGRect(x: rect.minX, y: span.at, width: rect.width, height: span.length))
                }
            }
        }
        /// Children end to end with gaps; what's left over is the last one's.
        func spans(_ needs: [CGFloat], from start: CGFloat, total: CGFloat) -> [(at: CGFloat, length: CGFloat)] {
            let n = needs.count
            let slack = max(total - needs.reduce(0, +) - CGFloat(n - 1) * m.gap, 0)
            var at = start
            return needs.enumerated().map { i, need in
                let length = i == n - 1 ? need + slack : need
                defer { at += length + m.gap }
                return (at, length)
            }
        }
        place(tree, root)
        return out
    }
}
