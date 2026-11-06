import BentoFilePreviewKit
import BentoFoundationKit
#if canImport(UIKit)
import UIKit
import GhosttyKit

extension GhosttyTerminalSurface {

    // MARK: - Touch scroll & mouse reporting

    /// Scroll the terminal (scrollback / copy-mode) by a touch delta in points.
    /// ghostty applies scroll at the tracked mouse position, so we set that to
    /// the touch point first (a hard-won lesson from the macOS scrollWheel path —
    /// without mouse_pos the engine ignores the scroll). `precise` marks the
    /// delta as high-resolution (touch), matching trackpad behavior.
    public func scroll(deltaX: CGFloat, deltaY: CGFloat, at point: CGPoint) {
        guard let surface else { return }
        // tmux has the pane in copy-mode: IT owns the viewport and repaints from
        // its own scroll position, so moving our scrollback as well means two
        // scroll positions for one screen — the finger drags and nothing appears
        // to happen. Hand the gesture to tmux's copy-mode instead.
        if tmuxInMode {
            let rows = copyModeScrollRows(deltaY)
            if rows != 0 { onCopyModeScroll?(rows) }
            return
        }
        // Mouse-reporting pane (an alt-screen TUI that enabled mouse tracking) →
        // forward the scroll to the program as wheel events instead of moving the
        // surface's local scrollback. Without this, scrolling in Claude Code's
        // fullscreen mode paged the terminal's own history rather than the TUI.
        if mouseReporting.any {
            forwardWheel(deltaY: deltaY, at: point)
            return
        }
        let p = pxPoint(point)
        ghostty_surface_mouse_pos(surface, p.0, p.1, GHOSTTY_MODS_NONE)
        // bit 0 = high-precision; momentum left at NONE (touch drag, not inertial).
        let mods: Int32 = 1
        // ghostty's precise-scroll path interprets the delta in DEVICE PIXELS —
        // it divides by the cell's pixel height to convert to rows. The pan
        // gesture reports finger movement in POINTS, so on a 2×/3× screen the
        // raw delta was 2-3× too small: you had to swipe several row-heights to
        // move one line. Scale points → pixels so scrolling tracks the finger 1:1
        // (renderScale: the drawable's actual pixel density, see its doc).
        let s = Double(renderScale)
        ghostty_surface_mouse_scroll(surface, Double(deltaX) * s, Double(deltaY) * s, mods)
        ghostty_surface_refresh(surface)
        setNeedsDraw()
    }

    /// Forward a touch-scroll to a mouse-reporting program as wheel events. The
    /// pan delta is continuous, so accumulate it and emit one wheel report per
    /// whole cell-row crossed. Finger DOWN (deltaY > 0) reveals older content =
    /// wheel-up (button 64); finger up = wheel-down (65) — matching the local
    /// scrollback direction.
    private func forwardWheel(deltaY: CGFloat, at point: CGPoint) {
        guard let cell = cellSize else { return }
        let rows = wheelRows.rows(adding: deltaY, rowHeight: cell.height)
        guard rows != 0 else { return }
        let button = rows > 0 ? 64 : 65
        let (col, row) = cellCoord(point)
        // A wheel notch is a press with no release — there is no "wheel up" event.
        for _ in 0..<min(abs(rows), 8) { sendMouse(button: button, press: true, col: col, row: row) }
    }

    /// Forward a tap to a mouse-reporting program as a left-button press followed
    /// by a release on the tapped cell — the touch equivalent of a click.
    /// Returns false when no program owns the mouse, so the host can fall back to
    /// Bento's own tap handling.
    ///
    /// Without this, `scroll` forwarded the wheel and nothing else did anything:
    /// you could scroll an alt-screen TUI but never press anything in it, which
    /// is most of what Claude Code's fullscreen mode is made of. Press and
    /// release go out together because a touch has no hover — there is no state
    /// in between for the program to observe.
    @discardableResult
    public func forwardTap(at point: CGPoint) -> Bool {
        guard mouseReporting.any else { return false }
        let (col, row) = cellCoord(point)
        sendMouse(button: 0, press: true, col: col, row: row)
        sendMouse(button: 0, press: false, col: col, row: row)
        return true
    }

    /// Accumulate a pan delta into whole rows for copy-mode. Same points-per-row
    /// as the local scrollback path, so a pane in copy-mode scrolls at the speed
    /// every other pane does.
    private func copyModeScrollRows(_ deltaY: CGFloat) -> Int {
        guard let cell = cellSize else { return 0 }
        let rows = copyModeRows.rows(adding: deltaY, rowHeight: cell.height)
        guard rows != 0 else { return 0 }
        // Cap the burst: a flick would otherwise hand tmux a very large repeat
        // count in one command, and over a laggy link that lands as a lurch.
        return max(-12, min(12, rows))
    }

    /// 1-based cell (col,row) under a view point.
    private func cellCoord(_ point: CGPoint) -> (col: Int, row: Int) {
        GhosttyCellGeometry.cell(at: point, size: currentSize, scale: renderScale)
    }

    /// One cell in points at the scale the drawable renders at, or nil before
    /// the engine has reported a size.
    var cellSize: CGSize? { GhosttyCellGeometry.cellSize(currentSize, scale: renderScale) }

    /// Encode a mouse event and send it to the program via `onInput`. `button`:
    /// 0 = left, 64 = wheel-up, 65 = wheel-down. No modifier bits — a touch has
    /// no modifier keys to carry. Encoding is shared with the Mac surface
    /// (`MouseReport`) so the two can't drift.
    private func sendMouse(button: Int, press: Bool, col: Int, row: Int) {
        onInput?(MouseReport.encode(button: button, press: press, col: col, row: row,
                                    sgr: mouseReporting.sgr))
    }

    // Per-surface engine actions — mostly no-ops on iOS (no pointer cursor).
    public func handleMouseShape(_ shape: ghostty_action_mouse_shape_e) {}
    public func handleMouseVisibility(_ visible: Bool) {}
}
#endif
