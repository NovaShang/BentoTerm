import Foundation
import CoreGraphics

/// Per-surface façade over `PathHitTester`: converts a tap/hover point into a
/// path candidate plus highlight rects in the surface's own point space.
/// Owned by each `GhosttyTerminalSurface` (iOS and macOS) — the surfaces feed
/// it their platform-specific inputs (cell size, viewport rows, scrollbar
/// state, `readScrollback`) and this class handles the shared math + caching.
///
/// Caching: the tester is rebuilt when the scroll position changes, the wrap
/// width changes, or the snapshot is older than `maxAge` (so hover during
/// streaming output stays fresh). A hover storm on a still screen re-uses one
/// snapshot instead of re-reading the whole scrollback per mouse-move.
@MainActor
public final class SurfacePathHitEngine {

    public struct Hit {
        public let candidate: PathDetector.Candidate
        /// Highlight rects (one per visual row the token crosses), clipped to
        /// the viewport, in surface points.
        public let rects: [CGRect]
    }

    /// One tap candidate with its highlight geometry — see
    /// `PathHitTester.TapCandidate` for the verification contract.
    public struct TapHit {
        public let path: String
        public let line: Int?
        public let column: Int?
        /// Self-contained explicit token — UI may show it without a stat.
        public let fastPath: Bool
        public let rects: [CGRect]
    }

    /// Everything a tap yields: ordered candidates plus root hints for the
    /// resolver's screen-context fallback.
    public struct TapScan {
        public let hits: [TapHit]
        /// Directories gleaned from absolute/`~` paths visible near the tap.
        public let rootHints: [String]
        public static let empty = TapScan(hits: [], rootHints: [])
    }

    public init() {}

    private var tester: PathHitTester?
    private var cacheCols = 0
    private var cacheScrollKey: UInt64 = .max
    private var builtAt: CFAbsoluteTime = 0
    private static let maxAge: CFAbsoluteTime = 0.4

    /// Drop the cached snapshot (e.g. after the surface is recreated).
    public func invalidate() { tester = nil }

    /// - Parameters:
    ///   - point: tap/hover location in surface points (top-left origin).
    ///   - cellSize: one cell in points.
    ///   - viewportRows: ghostty's current row count.
    ///   - cols: wrap width for the visual-row math (tmux `pane.width`, or the
    ///     surface's own column count).
    ///   - scrollTop: viewport-top row from the last SCROLLBAR action, nil if
    ///     none arrived yet (assume pinned to the bottom).
    ///   - readText: whole-scrollback snapshot (`read_text(SCREEN)`).
    public func hit(point: CGPoint, cellSize: CGSize, viewportRows: Int, cols: Int,
                    scrollTop: Int?, readText: () -> String?) -> Hit? {
        guard let (tester, top, row, col) = prepare(point: point, cellSize: cellSize,
                                                    viewportRows: viewportRows, cols: cols,
                                                    scrollTop: scrollTop, readText: readText)
        else { return nil }
        guard let hit = tester.hit(absRow: top + row, col: col) else { return nil }
        let rects = rects(for: hit.spans, top: top, viewportRows: viewportRows, cellSize: cellSize)
        guard !rects.isEmpty else { return nil }
        return Hit(candidate: hit.candidate, rects: rects)
    }

    /// Tap candidates under `point`, best-first (wrap-chain joins before the
    /// bare fragment) — parameters as in `hit`. Callers verify in order via
    /// `SmartPathResolver.resolveFirst` unless `hits[0].fastPath`.
    public func tapHits(point: CGPoint, cellSize: CGSize, viewportRows: Int, cols: Int,
                        scrollTop: Int?, readText: () -> String?) -> TapScan {
        guard let (tester, top, row, col) = prepare(point: point, cellSize: cellSize,
                                                    viewportRows: viewportRows, cols: cols,
                                                    scrollTop: scrollTop, readText: readText)
        else { return .empty }
        let hits: [TapHit] = tester.tapCandidates(absRow: top + row, col: col).compactMap { c in
            let rects = rects(for: c.spans, top: top, viewportRows: viewportRows, cellSize: cellSize)
            guard !rects.isEmpty else { return nil }
            return TapHit(path: c.path, line: c.line, column: c.column,
                          fastPath: c.fastPath, rects: rects)
        }
        guard !hits.isEmpty else { return .empty }
        // Hints only matter when something needs resolving.
        let hints = hits[0].fastPath ? [] : tester.rootHints(absRow: top + row)
        return TapScan(hits: hits, rootHints: hints)
    }

    /// Shared entry: guards, tap→cell math, snapshot cache. Returns the
    /// tester plus the viewport-top row and the tapped (row, col).
    private func prepare(point: CGPoint, cellSize: CGSize, viewportRows: Int, cols: Int,
                         scrollTop: Int?, readText: () -> String?)
        -> (tester: PathHitTester, top: Int, row: Int, col: Int)? {
        guard PathPreviewSettings.isEnabled,
              cellSize.width > 0, cellSize.height > 0,
              viewportRows > 0, cols > 0 else { return nil }
        let col = Int(point.x / cellSize.width)
        let row = Int(point.y / cellSize.height)
        guard col >= 0, col < cols, row >= 0, row < viewportRows else { return nil }

        let scrollKey = UInt64(bitPattern: Int64(scrollTop ?? -1))
        let now = CFAbsoluteTimeGetCurrent()
        if tester == nil || cacheCols != cols || cacheScrollKey != scrollKey
            || now - builtAt > Self.maxAge {
            guard let text = readText() else { return nil }
            tester = PathHitTester(screenText: text, cols: cols)
            cacheCols = cols
            cacheScrollKey = scrollKey
            builtAt = now
        }
        guard let tester else { return nil }
        let top = scrollTop ?? max(0, tester.totalVisualRows - viewportRows)
        return (tester, top, row, col)
    }

    private func rects(for spans: [PathHitTester.Hit.Span], top: Int,
                       viewportRows: Int, cellSize: CGSize) -> [CGRect] {
        spans.compactMap { span in
            let viewRow = span.row - top
            guard viewRow >= 0, viewRow < viewportRows else { return nil }
            return CGRect(x: CGFloat(span.startCol) * cellSize.width,
                          y: CGFloat(viewRow) * cellSize.height,
                          width: CGFloat(span.endCol - span.startCol) * cellSize.width,
                          height: cellSize.height)
        }
    }
}
