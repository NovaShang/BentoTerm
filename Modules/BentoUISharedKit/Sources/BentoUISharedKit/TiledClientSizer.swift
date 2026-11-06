import Foundation
import CoreGraphics

/// The tmux client-size bookkeeping both tiled hosts (the Mac's
/// `GhosttyTiledPaneHost`, iOS's `PaneContainerVC`) used to keep by hand: the
/// font's cell size as the surfaces last reported it, the grid last sent to
/// tmux, and the 60 ms debounce in front of `refresh-client`.
///
/// What it deliberately does NOT decide: WHICH grid to push (the hosts measure
/// that — window bounds, a surface's own report, the iOS pinned page, the
/// safe area), whether a push is allowed (the view model gates the wire), or
/// when a drag ends. The hosts keep all of that.
@MainActor
public final class TiledClientSizer {
    public struct Grid: Equatable, Sendable {
        public let cols: Int
        public let rows: Int
        public init(cols: Int, rows: Int) {
            self.cols = cols
            self.rows = rows
        }
    }

    /// Typing-speed resizes (a window drag, a rotation) collapse into one
    /// `refresh-client` — each one makes every TUI in the session redraw.
    public static let defaultDebounce: DispatchTimeInterval = .milliseconds(60)

    /// One cell of the font in device pixels, as a surface last reported it;
    /// nil until one has (or since `reset`).
    public private(set) var cellPx: CGSize?
    /// The grid last handed to tmux — the dedupe key.
    public private(set) var lastPushed: Grid?
    /// A grid measured while the host was holding (a live window drag),
    /// waiting for `flush`.
    public private(set) var held: Grid?

    private let push: (Grid) -> Void
    private let debounce: DispatchTimeInterval
    private var work: DispatchWorkItem?

    public init(debounce: DispatchTimeInterval = TiledClientSizer.defaultDebounce,
                push: @escaping (Grid) -> Void) {
        self.debounce = debounce
        self.push = push
    }

    /// Take a surface's reported cell size. Returns true when it CHANGED, so
    /// the host re-measures and re-tiles.
    ///
    /// Learned on every change, not just the first report: the size is in
    /// device pixels, so it moves when the font does or when a Mac window
    /// crosses to a display with another backing scale. Learning only once
    /// left the grid on the old font's cells (iOS), and on the Mac it raced
    /// the backing-change reset — a report that landed first was dropped and
    /// the text stayed huge or tiny until relaunch.
    @discardableResult
    public func learn(cellWidthPx: Int, cellHeightPx: Int) -> Bool {
        guard cellWidthPx > 0, cellHeightPx > 0 else { return false }
        let cell = CGSize(width: cellWidthPx, height: cellHeightPx)
        guard cell != cellPx else { return false }
        cellPx = cell
        return true
    }

    /// Points per tmux cell at `scale`, or nil until a cell size is known.
    public func pointsPerCell(scale: CGFloat) -> CGSize? {
        guard let cellPx, scale > 0 else { return nil }
        return CGSize(width: cellPx.width / scale, height: cellPx.height / scale)
    }

    /// Ask for `grid` to be the client size. Dropped if it's what tmux already
    /// has; otherwise sent after the debounce, replacing any send still
    /// waiting. `holding` (a live window drag) parks it for `flush` instead,
    /// so the TUI gets one SIGWINCH on mouse-up rather than a burst.
    /// `afterPush` runs right after this grid is sent.
    public func request(_ grid: Grid, holding: Bool = false,
                        afterPush: (() -> Void)? = nil) {
        guard grid.cols > 0, grid.rows > 0 else { return }
        if holding { held = grid; return }
        guard grid != lastPushed else { return }
        lastPushed = grid
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.work = nil
            self.push(grid)
            afterPush?()
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    /// The hold is over: send the parked grid now (no debounce — the drag
    /// already was one), unless tmux already has it.
    public func flush() {
        guard let grid = held else { return }
        held = nil
        guard grid != lastPushed else { return }
        lastPushed = grid
        push(grid)
    }

    /// Send `grid` now even if unchanged — re-asserting this client's size
    /// after another client shrank the shared session (which the dedupe would
    /// otherwise swallow).
    public func pushNow(_ grid: Grid) {
        lastPushed = grid
        push(grid)
    }

    /// The font or the display changed: forget the cell size and what was
    /// pushed, so the next surface report re-learns and re-pushes.
    public func reset() {
        cellPx = nil
        lastPushed = nil
    }
}
