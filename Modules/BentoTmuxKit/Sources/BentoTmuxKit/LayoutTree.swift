import Foundation

/// Editable model of a tmux window-layout string, for Bento's mode switch.
///
/// When a List-mode session merges back into one Tiled window, the saved
/// layout may no longer match the live pane set: windows were opened or
/// closed while in List mode. Rather than throwing the remembered arrangement
/// away, the layout TREE is edited — departed panes' cells collapse into a
/// sibling, newcomers split the largest cell along its longer edge — so
/// survivors return to exactly their old spots.
///
/// Format (tmux layout-custom.c):
///   layout   := checksum "," node
///   node     := leaf | hsplit | vsplit
///   leaf     := WxH,X,Y,paneNumber
///   hsplit   := WxH,X,Y "{" node ("," node)+ "}"   (children side by side)
///   vsplit   := WxH,X,Y "[" node ("," node)+ "]"   (children stacked)
/// Siblings are separated by a one-cell divider, so a container's extent on
/// its axis = sum(children) + (n-1).
///
/// IMPORTANT: `select-layout` assigns the window's panes to leaves in tree
/// (depth-first) order — the pane ids embedded in the string are ignored.
/// Callers must therefore order the window's panes to match `leafOrder(of:)`
/// before applying an edited layout (Bento's merge chains `join-pane` in that
/// order).
public enum TmuxLayoutTree {
    public indirect enum Node: Equatable, Sendable {
        case leaf(id: Int, w: Int, h: Int, x: Int, y: Int)
        case hsplit(w: Int, h: Int, x: Int, y: Int, children: [Node])
        case vsplit(w: Int, h: Int, x: Int, y: Int, children: [Node])

        var width: Int {
            switch self {
            case .leaf(_, let w, _, _, _), .hsplit(let w, _, _, _, _), .vsplit(let w, _, _, _, _): return w
            }
        }
        var height: Int {
            switch self {
            case .leaf(_, _, let h, _, _), .hsplit(_, let h, _, _, _), .vsplit(_, let h, _, _, _): return h
            }
        }
    }

    // MARK: - Parse

    /// Parse a layout string (with or without its leading checksum).
    public static func parse(_ layout: String) -> Node? {
        var body = Substring(layout)
        // Strip "abcd," checksum prefix when present (4 hex digits).
        if let comma = body.firstIndex(of: ","),
           body.distance(from: body.startIndex, to: comma) == 4,
           body[..<comma].allSatisfy(\.isHexDigit) {
            body = body[body.index(after: comma)...]
        }
        var scanner = body[...]
        let node = parseNode(&scanner)
        return node  // trailing garbage tolerated
    }

    private static func parseNode(_ s: inout Substring) -> Node? {
        guard let w = parseInt(&s), s.first == "x" else { return nil }
        s.removeFirst()
        guard let h = parseInt(&s), s.first == "," else { return nil }
        s.removeFirst()
        guard let x = parseInt(&s), s.first == "," else { return nil }
        s.removeFirst()
        guard let y = parseInt(&s) else { return nil }

        switch s.first {
        case "{", "[":
            let isH = (s.first == "{")
            let close: Character = isH ? "}" : "]"
            s.removeFirst()
            var children: [Node] = []
            while true {
                guard let child = parseNode(&s) else { return nil }
                children.append(child)
                if s.first == "," { s.removeFirst(); continue }
                if s.first == close { s.removeFirst(); break }
                return nil
            }
            return isH ? .hsplit(w: w, h: h, x: x, y: y, children: children)
                       : .vsplit(w: w, h: h, x: x, y: y, children: children)
        case ",":
            s.removeFirst()
            guard let id = parseInt(&s) else { return nil }
            return .leaf(id: id, w: w, h: h, x: x, y: y)
        default:
            return nil
        }
    }

    private static func parseInt(_ s: inout Substring) -> Int? {
        let digits = s.prefix(while: \.isNumber)
        guard !digits.isEmpty, let v = Int(digits) else { return nil }
        s = s.dropFirst(digits.count)
        return v
    }

    // MARK: - Serialize

    /// Render a node back to a full layout string, checksum included.
    public static func serialize(_ node: Node) -> String {
        let body = serializeNode(node)
        return String(format: "%04x,", checksum(body)) + body
    }

    private static func serializeNode(_ node: Node) -> String {
        switch node {
        case .leaf(let id, let w, let h, let x, let y):
            return "\(w)x\(h),\(x),\(y),\(id)"
        case .hsplit(let w, let h, let x, let y, let children):
            return "\(w)x\(h),\(x),\(y){" + children.map(serializeNode).joined(separator: ",") + "}"
        case .vsplit(let w, let h, let x, let y, let children):
            return "\(w)x\(h),\(x),\(y)[" + children.map(serializeNode).joined(separator: ",") + "]"
        }
    }

    /// tmux's layout checksum (layout-custom.c): rotate-right-by-1 then add
    /// each byte, over the body AFTER the "xxxx," prefix.
    static func checksum(_ body: String) -> UInt16 {
        var csum: UInt16 = 0
        for byte in body.utf8 {
            csum = (csum >> 1) &+ ((csum & 1) << 15)
            csum = csum &+ UInt16(byte)
        }
        return csum
    }

    // MARK: - Editing

    /// The pane ids of the leaves in depth-first order — the order
    /// `select-layout` will assign the window's panes in.
    public static func leafOrder(of node: Node) -> [Int] {
        switch node {
        case .leaf(let id, _, _, _, _): return [id]
        case .hsplit(_, _, _, _, let children), .vsplit(_, _, _, _, let children):
            return children.flatMap(leafOrder)
        }
    }

    /// Remove a pane's leaf; its cell collapses into a sibling (the container
    /// renormalizes, so the space is shared proportionally — visually the
    /// neighbors absorb it). Returns nil when the pane isn't present or it
    /// was the only leaf.
    public static func removing(pane id: Int, from node: Node) -> Node? {
        guard let pruned = prune(id, node) else { return nil }
        return renormalized(pruned, w: node.width, h: node.height, x: 0, y: 0)
    }

    private static func prune(_ id: Int, _ node: Node) -> Node? {
        switch node {
        case .leaf(let lid, _, _, _, _):
            return lid == id ? nil : node
        case .hsplit(let w, let h, let x, let y, let children):
            // No "unchanged" shortcut on child COUNT — a grandchild edit
            // doesn't change it. Always rebuild from the pruned children.
            let kept = children.compactMap { prune(id, $0) }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0] }             // container dissolves
            return .hsplit(w: w, h: h, x: x, y: y, children: kept)
        case .vsplit(let w, let h, let x, let y, let children):
            let kept = children.compactMap { prune(id, $0) }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0] }
            return .vsplit(w: w, h: h, x: x, y: y, children: kept)
        }
    }

    /// Insert a new pane by splitting the largest leaf along its longer edge
    /// — where a person would put it to keep the arrangement balanced, and
    /// nobody else moves. Same-axis nesting is flattened into the parent
    /// container (tmux's own canonical form).
    public static func inserting(pane id: Int, into node: Node) -> Node {
        guard let target = largestLeaf(node) else { return node }
        let split = splitLeaf(target, adding: id, in: node)
        return renormalized(split, w: node.width, h: node.height, x: 0, y: 0)
    }

    private static func largestLeaf(_ node: Node) -> Int? {
        var best: (id: Int, area: Int)?
        func walk(_ n: Node) {
            switch n {
            case .leaf(let id, let w, let h, _, _):
                let area = w * h
                if best == nil || area > best!.area { best = (id, area) }
            case .hsplit(_, _, _, _, let c), .vsplit(_, _, _, _, let c):
                c.forEach(walk)
            }
        }
        walk(node)
        return best?.id
    }

    /// Replace leaf `target` with a split of {target, new}. `parentAxisH`
    /// tells whether the enclosing container is horizontal, so a same-axis
    /// split becomes a sibling insertion instead of a nested container.
    private static func splitLeaf(_ target: Int, adding newID: Int, in node: Node) -> Node {
        func rebuild(_ n: Node) -> Node {
            switch n {
            case .leaf(let id, let w, let h, let x, let y):
                guard id == target else { return n }
                // Longer edge decides the axis: wide → side-by-side, tall → stacked.
                if w >= h {
                    let left = (w - 1) / 2, right = w - 1 - left
                    return .hsplit(w: w, h: h, x: x, y: y, children: [
                        .leaf(id: id, w: left, h: h, x: x, y: y),
                        .leaf(id: newID, w: right, h: h, x: x + left + 1, y: y),
                    ])
                } else {
                    let top = (h - 1) / 2, bottom = h - 1 - top
                    return .vsplit(w: w, h: h, x: x, y: y, children: [
                        .leaf(id: id, w: w, h: top, x: x, y: y),
                        .leaf(id: newID, w: w, h: bottom, x: x, y: y + top + 1),
                    ])
                }
            case .hsplit(let w, let h, let x, let y, let children):
                var out: [Node] = []
                for child in children.map(rebuild) {
                    // Flatten same-axis nesting (canonical tmux form).
                    if case .hsplit(_, _, _, _, let grand) = child, containsLeaf(newID, in: child), grand.count == 2 {
                        out.append(contentsOf: grand)
                    } else {
                        out.append(child)
                    }
                }
                return .hsplit(w: w, h: h, x: x, y: y, children: out)
            case .vsplit(let w, let h, let x, let y, let children):
                var out: [Node] = []
                for child in children.map(rebuild) {
                    if case .vsplit(_, _, _, _, let grand) = child, containsLeaf(newID, in: child), grand.count == 2 {
                        out.append(contentsOf: grand)
                    } else {
                        out.append(child)
                    }
                }
                return .vsplit(w: w, h: h, x: x, y: y, children: out)
            }
        }
        return rebuild(node)
    }

    private static func containsLeaf(_ id: Int, in node: Node) -> Bool {
        leafOrder(of: node).contains(id)
    }

    // MARK: - Renormalize

    /// Recompute every node's size and offset: distribute each container's
    /// extent to its children proportionally to their previous sizes (with
    /// one divider cell between siblings), recursively. Keeps the tree
    /// internally consistent after structural edits, which tmux requires.
    private static func renormalized(_ node: Node, w: Int, h: Int, x: Int, y: Int) -> Node {
        switch node {
        case .leaf(let id, _, _, _, _):
            return .leaf(id: id, w: w, h: h, x: x, y: y)
        case .hsplit(_, _, _, _, let children):
            let sizes = distribute(total: w, weights: children.map { max($0.width, 1) })
            var cx = x
            var out: [Node] = []
            for (child, cw) in zip(children, sizes) {
                out.append(renormalized(child, w: cw, h: h, x: cx, y: y))
                cx += cw + 1
            }
            return .hsplit(w: w, h: h, x: x, y: y, children: out)
        case .vsplit(_, _, _, _, let children):
            let sizes = distribute(total: h, weights: children.map { max($0.height, 1) })
            var cy = y
            var out: [Node] = []
            for (child, ch) in zip(children, sizes) {
                out.append(renormalized(child, w: w, h: ch, x: x, y: cy))
                cy += ch + 1
            }
            return .vsplit(w: w, h: h, x: x, y: y, children: out)
        }
    }

    /// Split `total` (minus n-1 divider cells) proportionally to `weights`,
    /// each part ≥1, rounding drift absorbed by the last part.
    private static func distribute(total: Int, weights: [Int]) -> [Int] {
        let n = weights.count
        let available = max(total - (n - 1), n)   // ≥1 cell each
        let sum = weights.reduce(0, +)
        var out: [Int] = []
        var used = 0
        for (i, weight) in weights.enumerated() {
            if i == n - 1 {
                out.append(max(available - used, 1))
            } else {
                let share = max(Int((Double(available) * Double(weight) / Double(sum)).rounded()), 1)
                out.append(share)
                used += share
            }
        }
        return out
    }
}
